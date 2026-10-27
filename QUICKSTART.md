# pgtwin - Quick Start Guide

**pgtwin** is a PostgreSQL High Availability OCF resource agent for **2-node clusters** using Pacemaker and Corosync.

---

## Prerequisites

- 2 Linux nodes (SUSE/openSUSE/RHEL/CentOS)
- **Choose deployment mode**:
  - **Bare-Metal**: PostgreSQL 17.x installed on both nodes
  - **Container**: Podman or Docker installed (PostgreSQL runs in containers)
- Pacemaker 3.0.1+ and Corosync installed
- Network connectivity between nodes
- Optional: Shared block device for SBD STONITH fencing

---
## Part 1: PostgreSQL Configuration for HA -- Bare-Metal Mode

### 1.1 Install PostgreSQL 17

```bash
# On both nodes (openSUSE/SUSE)
sudo zypper ref
sudo zypper up   # or 'zypper dup' on Tumbleweed

# On both nodes (openSUSE/SUSE)
sudo zypper install postgresql17 postgresql17-server postgresql17-contrib sudo

# On both nodes (RHEL/CentOS)
sudo dnf install postgresql17 postgresql17-server postgresql17-contrib

**NOTE**: There seems to be an issue installing postgresql17 at least in Tumbleweed, where it also installs postgres-18. This is not addressed here.

**IMPORTANT**: After installing `postgresql17-server`, the binaries may not be linked to `/usr/bin`. You need to create the symlinks manually:

```bash
# On both nodes - Link PostgreSQL binaries via alternatives system
# Step 1: Create symlinks in /etc/alternatives pointing to PostgreSQL 17 binaries
for f in /usr/lib/postgresql17/bin/*; do
    sudo ln -sf "$f" "/etc/alternatives/$(basename "$f")"
done

# Step 2: Create symlinks in /usr/bin pointing to alternatives
for f in /usr/lib/postgresql17/bin/*; do
    sudo ln -sf "/etc/alternatives/$(basename "$f")" "/usr/bin/$(basename "$f")"
done

# Verify binaries are accessible
which psql pg_ctl initdb
psql --version
```

This creates a two-tier symlink structure:
- `/usr/bin/psql` → `/etc/alternatives/psql` → `/usr/lib/postgresql17/bin/psql`
- This allows easy switching between PostgreSQL versions using the alternatives system
```

### 1.2 Initialize PostgreSQL (Primary Node Only)

```bash
# On node 1 only
sudo systemctl start postgresql
sudo systemctl stop postgresql
```

### 1.3 Configure PostgreSQL for Replication

Create `/var/lib/pgsql/data/postgresql.custom.conf`:

```ini
# HA CRITICAL SETTINGS
restart_after_crash = off              # CRITICAL: Must be 'off' for Pacemaker
wal_level = replica                    # REQUIRED for physical replication
max_wal_senders = 16                   # REQUIRED (minimum: 2)
max_replication_slots = 16             # REQUIRED (match wal_senders)
hot_standby = on                       # Allows read queries on standby

# PRODUCTION TIMEOUTS (v1.5 standards)
wal_sender_timeout = 30000             # 30 seconds (prevents false disconnections)
max_standby_streaming_delay = 60000    # 60 seconds (bounds replication lag)
max_standby_archive_delay = 60000      # 60 seconds (bounds replication lag)

# NETWORK & CONNECTION
port = 5432                            # PostgreSQL listening port (change if running multiple instances)
listen_addresses = '*'                 # Or specific IPs: 'localhost,192.168.122.60'

# REPLICATION
synchronous_commit = on                # For zero data loss (sync replication)
synchronous_standby_names = ''         # IMPORTANT: Start with empty (async mode) - pgtwin will enable sync based on rep_mode

# ARCHIVE (optional - for PITR)
archive_mode = off                     # Enable if you need point-in-time recovery
# archive_command = 'rsync -a %p /archive/%f || /bin/true'  # Must have error handling!

# LOGGING
log_destination = 'stderr'
logging_collector = on
log_directory = 'log'
log_filename = 'postgresql-%a.log'
log_truncate_on_rotation = on
log_rotation_age = 1d
log_line_prefix = '%t [%p]: [%l-1] user=%u,db=%d,app=%a,client=%h '
log_checkpoints = on
log_connections = on
log_disconnections = on
log_lock_waits = on
log_temp_files = 0
log_autovacuum_min_duration = 0
log_replication_commands = on
```

Include custom config in `/var/lib/pgsql/data/postgresql.conf`:

```ini
include = 'postgresql.custom.conf'
```

**Using Non-Standard Ports**:

If you change the port (e.g., `port = 5433` for running multiple PostgreSQL versions):
- Update `postgresql.custom.conf` on both nodes
- Match the port in cluster configuration: `pgport="5433"` (see section 2.7)
- Update firewall rules to allow the new port
- This allows running multiple PostgreSQL instances on the same host

### 1.4 Configure pg_hba.conf

Edit `/var/lib/pgsql/data/pg_hba.conf`:

```
# TYPE  DATABASE        USER            ADDRESS                 METHOD

# Local connections
local   all             all                                     peer
host    all             all             127.0.0.1/32            scram-sha-256
host    all             all             ::1/128                 scram-sha-256

# Replication connections from cluster network
host    replication     replicator      192.168.122.0/24        scram-sha-256

# Application connections
host    all             all             192.168.122.0/24        scram-sha-256
```

### 1.5 Start PostgreSQL on Primary (Temporarily)

Start PostgreSQL on node 1 to create the replication user:

```bash
# On node 1 only - start PostgreSQL temporarily
sudo systemctl start postgresql

# Test connection
sudo -u postgres psql -c "SELECT version();"
sudo -u postgres psql -c "SHOW wal_level;"
sudo -u postgres psql -c "SHOW restart_after_crash;"  # Must show 'off'
```

**Note**: Since `synchronous_standby_names = ''` (async mode) in our initial configuration, PostgreSQL will start normally without hanging. pgtwin will enable synchronous replication automatically based on the cluster's `rep_mode` parameter once both nodes are online.

### 1.6 Create Replication User

```bash
# On primary node (while PostgreSQL is running)
sudo -u postgres psql << EOF
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'strong_password_here';
GRANT pg_read_all_data TO replicator;
EOF
```

### 1.6.1 Grant pg_rewind Permissions

**CRITICAL for fast recovery**: Grant the replication user permissions for pg_rewind to access system files. Without these permissions, pg_rewind will fail and pgtwin will fall back to the slower pg_basebackup.

```bash
# On primary node - grant pg_rewind system function permissions
sudo -u postgres psql << EOF
GRANT EXECUTE ON FUNCTION pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
EOF
```

**Why this is needed:**
- pg_rewind performs fast timeline reconciliation after failover
- Reads system files (`pg_control`, WAL files) to calculate minimal changes
- Without these grants: pg_rewind fails → falls back to full pg_basebackup (slow)
- With these grants: pg_rewind succeeds → seconds instead of minutes recovery

**Note:** These permissions are also required in `pg_hba.conf` (configured in section 1.4):
```
host    postgres     replicator      192.168.122.0/24        scram-sha-256
```

### 1.7 Create Replication Slot

```bash
# On primary node - create the replication slot for standby
sudo -u postgres psql << EOF
SELECT pg_create_physical_replication_slot('ha_slot');
EOF

# Verify slot creation
sudo -u postgres psql -c "SELECT * FROM pg_replication_slots;"
```

### 1.8 Configure /etc/hosts (Both Nodes)

Ensure nodes can resolve each other's hostnames:

```bash
# On both nodes - verify or add hostname resolution
sudo cat >> /etc/hosts <<EOF
192.168.122.60   psql1
192.168.122.120  psql2
EOF

# Test resolution
ping -c 1 psql1
ping -c 1 psql2
```

**NOTE**: Adjust IP addresses to match your network configuration. Alternatively, you can use IP addresses directly in `.pgpass` (see below).

### 1.9 Create .pgpass File (Both Nodes)

The `.pgpass` file is used for two purposes:
1. **Discovery queries**: Connect to `postgres` database to check which node is promoted
2. **Replication**: Connect to `replication` database for pg_basebackup

```bash
# On both nodes - using hostnames (requires /etc/hosts or DNS)
sudo -u postgres bash -c 'cat > /var/lib/pgsql/.pgpass << EOF
pg1:5432:replication:replicator:strong_password_here
pg2:5432:replication:replicator:strong_password_here
pg1:5432:postgres:replicator:strong_password_here
pg2:5432:postgres:replicator:strong_password_here
EOF'

sudo chmod 600 /var/lib/pgsql/.pgpass
sudo chown postgres:postgres /var/lib/pgsql/.pgpass

# Alternative: Use IP addresses if DNS/hostnames are unavailable
# sudo -u postgres bash -c 'cat > /var/lib/pgsql/.pgpass << EOF
# 192.168.122.60:5432:replication:replicator:strong_password_here
# 192.168.122.120:5432:replication:replicator:strong_password_here
# 192.168.122.60:5432:postgres:replicator:strong_password_here
# 192.168.122.120:5432:postgres:replicator:strong_password_here
# EOF'
```

**IMPORTANT**:
- Each node should have entries for **both** nodes (including itself)
- Each node needs **both** `replication` and `postgres` database entries
- pgtwin automatically filters out the local node entry
- Use either hostnames (with proper resolution) OR IP addresses consistently

### 1.10 Prepare Standby Node for Automatic Initialization

**NEW in v1.6.6**: pgtwin now **automatically initializes** standby nodes with empty PGDATA directories. No manual pg_basebackup required!

#### Recommended Approach: Controlled Startup Sequence

For first-time cluster setup, use a controlled startup to avoid race conditions:

```bash
# On node 2 - create an empty PGDATA directory
sudo mkdir -p /var/lib/pgsql/data
sudo chown postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data

# Put node 2 in standby mode (we'll bring it online after node 1 is promoted)
sudo crm node standby pg2
```

**What happens next:**
1. You'll configure the cluster in Part 2 (only node 1 will start initially)
2. Node 1 becomes promoted (primary)
3. You bring node 2 online → **automatic initialization triggers**
4. pgtwin will:
   - Detect the empty PGDATA directory
   - Discover the primary node (pg1)
   - Run pg_basebackup in the background
   - Configure replication settings
   - Start PostgreSQL as standby

**Why use controlled startup?**
- ✅ Cleaner logs (no "could not discover" warnings)
- ✅ No retry delays
- ✅ Primary is guaranteed to be ready before standby initializes
- ✅ Recommended for production deployments

**Note**: This is only needed for **first-time setup**. For ongoing operations (disk replacement, recovery), automatic initialization works immediately without any special sequencing.

#### Alternative: Simultaneous Startup

If you prefer to start both nodes simultaneously:

```bash
# On node 2 - just create an empty PGDATA directory
sudo mkdir -p /var/lib/pgsql/data
sudo chown postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data

# Don't put node in standby - let both start together
```

**Expected behavior:**
- You may see "WARNING: Could not discover promoted node" in logs
- This is **normal** - it's a timing issue during first startup
- pgtwin automatically retries every monitor interval
- Once pg1 is promoted, pg2 discovers it and completes initialization
- Total delay: ~30-60 seconds

**Monitor automatic initialization**:
```bash
# Watch Pacemaker logs for progress
sudo journalctl -u pacemaker -f

# Expected log sequence:
# 1. "WARNING: Could not discover promoted node" (initial retries, if simultaneous start)
# 2. "Discovered promoted node: pg1" (once primary is ready)
# 3. "Auto-initializing standby from primary: pg1"
# 4. "Basebackup in progress..." (progress updates)
# 5. "PostgreSQL started successfully" (complete)

# Watch pg_basebackup progress
sudo tail -f /var/lib/pgsql/.pgtwin_basebackup.log
```

#### Option B: Manual pg_basebackup (Alternative)

If you prefer to initialize manually (e.g., for faster first startup or to avoid retry warnings):

```bash
# On node 2 - copy from node 1 (use the replication slot created earlier)
sudo -u postgres pg_basebackup -h pg1 -U replicator -D /var/lib/pgsql/data -P -R -S ha_slot

# Verify standby.signal was created
ls -l /var/lib/pgsql/data/standby.signal
```

**NOTE**: The `-S ha_slot` parameter uses the replication slot created in step 1.7. This ensures the primary retains all necessary WAL files during the initial copy.

### 1.11 Stop PostgreSQL

```bash
# On node 1 - stop PostgreSQL - Pacemaker will manage it from now on
sudo systemctl stop postgresql
```

**NOTE**: pgtwin will manage `synchronous_standby_names` automatically based on the cluster's `rep_mode` parameter. When you configure the cluster with `rep_mode=sync`, pgtwin notify support will enable synchronous replication dynamically once both nodes are online.


### 1.12 Configure Firewall (Both Nodes)

If you're using firewalld, you need to open PostgreSQL port for replication:

```bash
# On both nodes
sudo firewall-cmd --permanent --add-service=postgresql
sudo firewall-cmd --reload

# Verify
sudo firewall-cmd --list-services
# Should show: dhcpv6-client high-availability postgresql ssh
```

**Why this is needed:**
- Auto-initialization requires connecting to the primary for discovery and pg_basebackup
- Without this, you'll see "No route to host" errors

---


---

## Part 2: Pacemaker Cluster Setup

### 2.1 Install Cluster Software (Both Nodes)

```bash
# openSUSE/SUSE
sudo zypper install pacemaker corosync crmsh resource-agents fence-agents-common fence-agents-sbd

# RHEL/CentOS
sudo dnf install pacemaker corosync pcs
```

### 2.2 Install pgtwin OCF Agent (Both Nodes)

```bash
# openSUSE Tumbleweed
sudo zypper ar https://download.opensuse.org/repositories/home:azouhr:d3v/openSUSE_Factory_standard azouhr-d3v
sudo zypper in pgtwin

# For others, there is no package available yet:
sudo cp pgtwin /usr/lib/ocf/resource.d/heartbeat/
sudo chmod +x /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify installation
ls -l /usr/lib/ocf/resource.d/heartbeat/pgtwin
```

### 2.3 Configure Cluster (Node 1)

```bash
sudo crm cluster init --name CLUSTERNAME
```

Answer the questions you are asked. For SBD, you will need a shared block device.

### 2.4 Configure Cluster (Node 2)

```bash
sudo crm cluster join
```

### 2.5 Configure Cluster Properties

```bash
# On node 1
sudo crm configure property \
  stonith-enabled=false \
  no-quorum-policy=ignore \
  cluster-recheck-interval=1min
```

**Note**: Set `stonith-enabled=true` in production with proper SBD configuration!

---

### 2.6 Prepare for PostgreSQL Resource

**Choose your deployment mode** and follow the appropriate preparation section:

#### 2.6.1 Bare-Metal Mode Preparation

**If using bare-metal mode** (PostgreSQL installed directly on hosts):

✅ **Checklist**:
- PostgreSQL 17 packages installed (from Part 1)
- postgres user exists (auto-created by package installation)
- PGDATA initialized and configured (from Part 1)

**No additional preparation needed** - proceed to section 2.7.

---

#### 2.6.2 Container Mode Preparation

> ⚠️ **EXPERIMENTAL FEATURE**
>
> Container mode is an experimental feature that has received limited production testing.
> While the implementation is technically sound and uses secure `--user` flag for proper
> UID/GID isolation, this deployment mode is newer than bare-metal deployments.
>
> **Recommendations**:
> - ✅ Use for testing and development environments
> - ✅ Use when PostgreSQL packages are not available for your platform
> - ⚠️ **For production**: Prefer bare-metal mode (section 2.6.1) until more field testing
> - ⚠️ Requires Podman 3.0+ or Docker 20.10+
> - ⚠️ Test thoroughly in staging before production use
>
> **Status**: Experimental - Feedback Welcome

**If using container mode** (PostgreSQL runs in containers):

**Step 1: Install Container Runtime** (Both Nodes)

```bash
# Install Podman (recommended) or Docker
sudo zypper install podman

# Verify installation
podman --version
```

**Step 2: Create PostgreSQL User** (Both Nodes)

Container mode requires a user on the host that matches the `pguser` parameter you'll configure in step 2.7.

**Default configuration** (`pguser` not specified, defaults to "postgres"):

```bash
# Check if postgres user exists
if ! id postgres &>/dev/null; then
    echo "Creating postgres user and group..."
    sudo groupadd -r postgres
    sudo useradd -r -g postgres -d /var/lib/pgsql -s /bin/bash -c "PostgreSQL Server" postgres
    sudo mkdir -p /var/lib/pgsql/data
    sudo chown postgres:postgres /var/lib/pgsql
fi

# Verify
id postgres
# Expected: uid=26(postgres) gid=26(postgres)  [openSUSE]
#           uid=999(postgres) gid=999(postgres) [RHEL/CentOS]
```

**Custom username** (if you plan to use `pguser="dbadmin"` or similar):

```bash
# Example: Creating "dbadmin" user instead of "postgres"
PGUSER="dbadmin"  # ← Change this to match your pguser parameter

if ! id "$PGUSER" &>/dev/null; then
    echo "Creating $PGUSER user and group..."
    sudo groupadd -r "$PGUSER"
    sudo useradd -r -g "$PGUSER" -d /var/lib/pgsql -s /bin/bash -c "PostgreSQL Server" "$PGUSER"
    sudo mkdir -p /var/lib/pgsql/data
    sudo chown "$PGUSER:$PGUSER" /var/lib/pgsql
fi
```

**⚠️ CRITICAL**: The username created here **MUST** match the `pguser` parameter in your cluster configuration (step 2.7).

**Step 3: Install Container Library** (Both Nodes)

```bash
# Install the container library
sudo cp pgtwin-container-lib.sh /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
sudo chmod 644 /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
```

**Container Mode Benefits**:
- ✅ No PostgreSQL packages needed on host
- ✅ Easy version switching (change `pg_major_version` parameter)
- ✅ Container isolation
- ✅ Same security model as bare-metal (uses `--user` flag)
- ✅ Parallel operation of different versions of PostgreSQL (Vendor or PostgreSQL Version)

**Ready** - proceed to section 2.7.

---

### 2.7 Create PostgreSQL Resource

**This configuration works for BOTH bare-metal and container mode.**

The only differences are the parameters marked with **[CONTAINER]** below.

```bash
sudo crm configure primitive postgres-db pgtwin \
  params \
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
    backup_before_basebackup="true" \
    basebackup_timeout="3600" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    slot_name="ha_slot" \
    # --- Container Mode Parameters (add these if using containers) ---
    # container_mode="true" \              # [CONTAINER] Enable container mode
    # pg_major_version="17" \              # [CONTAINER] PostgreSQL version
    # container_name="postgres-ha" \       # [CONTAINER] Container name
    # container_image="..." \              # [CONTAINER] Optional: custom image
    # pguser="postgres" \                  # [OPTIONAL] Custom username (default: postgres)
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted" \
  op promote timeout="120s" interval="0" \
  op demote timeout="120s" interval="0" \
  op notify timeout="90s" interval="0"
  meta notify=true promoted-max=1 clone-max=2 clone-node-max=1 interleave=true

```

**Parameter Guide**:

| Parameter | Bare-Metal | Container Mode | Notes |
|-----------|-----------|----------------|-------|
| `pgdata` | Required | Required | Same for both |
| `pgport` | Required | Required | Same for both |
| `rep_mode` | Required | Required | Same for both |
| `node_list` | Required | Required | Same for both |
| `pguser` | Optional | Optional | **If set, must match host username** |
| `container_mode` | - | **"true"** | Enables container mode |
| `pg_major_version` | - | **"17"** | PostgreSQL major version |
| `container_name` | - | **"postgres-ha"** | Container name |
| `container_image` | - | Optional | Custom image (auto-detected if not set) |

**Example: Bare-Metal Configuration**

```bash
sudo crm configure primitive postgres-db pgtwin \
  params \
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
    backup_before_basebackup="true" \
    basebackup_timeout="3600" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    slot_name="ha_slot" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted" \
  op promote timeout="120s" interval="0" \
  op demote timeout="120s" interval="0" \
  op notify timeout="90s" interval="0"
  meta notify=true promoted-max=1 clone-max=2 clone-node-max=1 interleave=true

```

**Example: Container Mode Configuration**

```bash
sudo crm configure primitive postgres-db pgtwin \
  params \
    container_mode="true" \
    pg_major_version="17" \
    container_name="postgres-ha" \
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
    backup_before_basebackup="true" \
    basebackup_timeout="3600" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    slot_name="ha_slot" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted" \
  op promote timeout="120s" interval="0" \
  op demote timeout="120s" interval="0" \
  op notify timeout="90s" interval="0" \
  meta notify=true promoted-max=1 clone-max=2 clone-node-max=1 interleave=true

```

---

### 2.8 Create Clone Resource

```bash
sudo crm configure clone postgres-clone postgres-db \
  meta \
    promotable="true" \
    promoted-node-max="1" \
    clone-max="2" \
    clone-node-max="1" \
    notify="true" \
    failure-timeout="5m" \
    migration-threshold="5" \
    interleave="true"
```

### 2.9 Create Virtual IP Resource

```bash
sudo crm configure primitive vip IPaddr2 \
  params ip="192.168.122.20" \
  op monitor interval="10s"
  meta is-managed=true target-role=Started
```

### 2.10 Create Network Monitoring Resource (Recommended)

The ping resource monitors external network connectivity and helps the cluster make intelligent failover decisions.

**Benefits:**
- Detects network isolation vs. complete node failure
- Prefers primary role on nodes with working external connectivity
- Prevents running database on nodes unreachable by clients
- Complements SBD/STONITH fencing

```bash
# Create ping resource - monitors gateway connectivity
sudo crm configure primitive ping-gateway ocf:pacemaker:ping \
  params \
    host_list="192.168.122.1" \
    multiplier="100" \
    attempts="3" \
    timeout="2" \
  op monitor interval="10s" timeout="20s"

# Clone to run on all nodes
sudo crm configure clone ping-clone ping-gateway \
  meta clone-max="2" clone-node-max="1"
```

**Configuration:**
- `host_list`: Gateway IP, DNS server, or critical network host to monitor
- `multiplier`: Score added when target is reachable (default: 100)
- `attempts`: Number of ping attempts before declaring failure
- `timeout`: Seconds to wait for each ping response

### 2.11 Create Constraints

```bash
# Set resource stickiness to prevent unnecessary failback.
# Use rsc_defaults: the old cluster property default-resource-stickiness is ignored by current Pacemaker.
# The Promoted role gets the stickiness twice (directly and through the colocated VIP), so the value has to
# stay below 75 for these locations, otherwise a primary without connectivity is not replaced (see below).
sudo crm configure rsc_defaults resource-stickiness=50

# ⚠️ CRITICAL: VIP MUST run on same node as promoted database
# This colocation constraint ensures VIP follows promoted (primary) instance
# Without this, VIP can run on wrong node → connection failures!
sudo crm configure colocation vip-with-postgres inf: vip postgres-clone:Promoted

# VIP starts after promotion
sudo crm configure order promote-before-vip Mandatory: postgres-clone:promote vip:start \
     symmetrical=false

# VIP stops before demotion
sudo crm configure order vip-stop-before-demote Mandatory: vip:stop postgres-clone:demote \
     symmetrical=false

# Prefer node 1 as primary
sudo crm configure location postgres-on-psql1 postgres-clone role=Promoted 100: psql1
sudo crm configure location postgres-on-psql2 postgres-clone role=Promoted 50: psql2

# Prefer promoted role on nodes with working network connectivity (if using ping resource)
sudo crm configure location prefer-connected-promoted postgres-clone role=Promoted \
     rule 200: pingd gt 0
```

**How resource placement works:**

**Scoring of the Promoted role** (measured with `crm_simulate` on Pacemaker 3.0.3, VIP colocated with the Promoted role):

`score = location + 10 (master-score) + 200 (if pingd > 0) + 2 x stickiness` for the node that holds the Promoted role,
`score = location + 10 + 200 (if pingd > 0)` for the other node. The stickiness counts twice because the VIP is colocated
with the Promoted role and is sticky itself.

**Resource stickiness (prevents unnecessary failback, must not block the connectivity failover):**
- Stickiness=50 adds 2 x 50 = 100 points to the node that is currently primary
- Prevents automatic migration back to the preferred node after recovery: needs `2 x stickiness >= 100 - 50` (a tie keeps the current primary), so stickiness >= 25
- Must stay below the connectivity bonus: `100 + 10 + 2 x stickiness < 50 + 10 + 200`, so stickiness < 75
- With stickiness 100 (the old default) a primary that lost its gateway ping keeps the Promoted role: 310 against 260
- Admin can still manually migrate: `sudo crm resource move postgres-clone psql1`

**Initial placement (fresh cluster start):** no node is the current primary, so only the location decides: psql1 (100) is preferred over psql2 (50).

**After failover (psql2 is now primary), both connected:**
- psql1: 100 + 10 + 200 = 310
- psql2: 50 + 10 + 200 + 100 (2 x stickiness) = 360
- Result: psql2 stays primary (prevents automatic failback)

**Primary loses connectivity (psql1 is primary, ping lost):**
- psql1: 100 + 10 + 100 (2 x stickiness) = 210
- psql2: 50 + 10 + 200 = 260
- Result: the connected standby is promoted

Check any change with the live CIB before you rely on it: `sudo crm_simulate -sL | grep "promotion score"`; to try the
connectivity case, copy the CIB (`cibadmin -Q > /tmp/c.xml`), set `pingd` to 0 on the primary
(`CIB_file=/tmp/c.xml crm_attribute -N <primary> -n pingd -v 0 -l reboot`) and run `crm_simulate -x /tmp/c.xml -s`.

### 2.12 Verify Configuration

```bash
# Check configuration syntax
sudo crm configure verify

# View full configuration
sudo crm configure show

# Check cluster status
sudo crm status
```

### 2.13 Bring Node 2 Online (If Using Controlled Startup)

If you put node 2 in standby mode in section 1.10, now bring it online:

```bash
# Bring node 2 online
sudo crm node online pg2

# Watch status
watch -n 2 'sudo crm status'
```

---

## Part 3: Verification

### 3.1 Check PostgreSQL Status

```bash
# On primary (promoted) node
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # Should be 'f' (false)
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# On standby (unpromoted) node
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"  # Should be 't' (true)
```

### 3.2 Test VIP

```bash
# From any node or client              
ping 192.168.122.20                    

# Connect via VIP
psql -h 192.168.122.20 -U postgres -c "SELECT inet_server_addr();"
```

### 3.3 Test Failover

```bash
# Trigger manual failover to node 2
sudo crm resource move postgres-clone psql2

# Watch status
sudo crm_mon

# IMPORTANT: Clear the constraint after move!
sudo crm resource clear postgres-clone 
```

---

## Part 4: Common Operations

### Check Cluster Status

```bash
sudo crm status
sudo crm_mon -1Afr
```

### Check PostgreSQL Logs

```bash
# Pacemaker logs. This is **strongly recommended**. pgtwin will print lots of warning if the configuration is not optimal.
sudo journalctl -u pacemaker -f

# PostgreSQL logs
sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log
```

### Manual Failover

```bash
# Move primary to specific node
sudo crm resource move postgres-clone <node_name>

# ALWAYS clear after move!
sudo crm resource clear postgres-clone
```

### Check Replication Lag

```bash
# On primary
sudo -u postgres psql -c "SELECT application_name, state, sync_state, pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes FROM pg_stat_replication;"
```

### Restart Resource

```bash
# Restart PostgreSQL resource on current node
sudo crm resource restart postgres-clone
```

### Stop/Start Cluster

```bash
# Stop all cluster resources
sudo crm resource stop postgres-clone

# Start all cluster resources
sudo crm resource start postgres-clone
```

---

## Troubleshooting

### Resource Won't Start

```bash
# Check pacemaker logs
sudo journalctl -u pacemaker -n 100

# Check PostgreSQL logs
sudo cat /var/lib/pgsql/data/log/postgresql-*.log

# Check resource agent output
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin start
```

### Split-Brain Prevention

**CRITICAL**: Ensure `restart_after_crash = off` in PostgreSQL configuration!

```bash
# Verify setting
sudo -u postgres psql -c "SHOW restart_after_crash;"  # MUST be 'off'
```

### Replication Not Working

```bash
# On primary - check connections
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# On standby - check replay status
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_wal_receiver;"

# Check .pgpass permissions
ls -l /var/lib/pgsql/.pgpass  # Should be 600, owned by postgres
```

### Configuration Validation Errors

The pgtwin agent performs automatic validation on startup. Check for:

```bash
# Look for validation messages in logs
sudo journalctl -u pacemaker | grep -E "CRITICAL ERROR|WARNING"

# Common issues:
# - restart_after_crash='on' → CRITICAL ERROR (must fix immediately!)
# - wal_sender_timeout < 10s → WARNING (increase to 15-30 seconds)
# - max_standby_streaming_delay=-1 → WARNING (set to 30-60 seconds)
```

### "Could not discover promoted node" Warning

**During initial cluster startup**, this warning is **expected and normal**:

```
WARNING: Could not discover promoted node via any method
```

**What's happening:**
- The standby node (pg2) starts before the primary (pg1) is fully promoted
- pgtwin retries automatically (Pacemaker handles this)
- Once pg1 is promoted, pg2 discovers it and proceeds

**This will resolve itself in 30-60 seconds.** If it persists for more than 2 minutes:

```bash
# Check if primary is promoted
crm_mon -1
# Should show: "Promoted: [ pg1 ]"

# If primary is promoted but standby still can't discover it:
# Check network connectivity
ping pg1  # From pg2

# Check PostgreSQL is listening
sudo -u postgres psql -h pg1 -p 5432 -l

# Check .pgpass configuration
cat /var/lib/pgsql/.pgpass
```

### Automatic Initialization Issues

If automatic standby initialization doesn't start after primary is promoted:

```bash
# 1. Verify .pgpass is configured correctly
ls -l /var/lib/pgsql/.pgpass  # Should be 600, owned by postgres
cat /var/lib/pgsql/.pgpass     # Should contain both replication and postgres entries

# 2. Check that primary node is running AND promoted
sudo crm status  # Look for "Promoted: [ pg1 ]"

# 3. Verify PGDATA is empty
ls -la /var/lib/pgsql/data/  # Should be empty

# 4. Check for sufficient disk space
df -h /var/lib/pgsql/data

# 5. Check firewall
sudo firewall-cmd --list-services  # Should include "postgresql"
ping pg1  # Should work
sudo -u postgres psql -h pg1 -p 5432 -U replicator -d postgres -c "SELECT 1"  # Should connect

# 6. Monitor initialization progress
sudo journalctl -u pacemaker -f | grep -i "auto-init\|basebackup\|discover"
sudo tail -f /var/lib/pgsql/.pgtwin_basebackup.log  # Note: file is in /var/lib/pgsql/, not data/
```

See FEATURE_AUTO_INITIALIZATION.md for detailed troubleshooting.

---

## Production Checklist

Before deploying to production, verify:

- ☑ **PostgreSQL Configuration**
  - `restart_after_crash = off` (CRITICAL - prevents split-brain)
  - `wal_level = replica`
  - `max_wal_senders >= 2`
  - `wal_sender_timeout >= 15000` (15 seconds minimum)
  - `max_standby_streaming_delay != -1` (set to 30000-60000)

- ☑ **Replication**
  - `.pgpass` file configured with proper permissions (0600)
  - Replication user created with correct grants
  - `pg_hba.conf` allows replication from standby node
  - Replication slot created and active

- ☑ **Cluster Configuration**
  - STONITH enabled (`stonith-enabled=true`)
  - Fencing device configured and tested
  - VIP configured and reachable
  - Both nodes have identical pgtwin agent version
  - Location constraints configured for both nodes

- ☑ **Testing**
  - Manual failover tested successfully
  - Automatic failover tested (node power-off)
  - Replication lag monitored (<1 second normal)
  - VIP migration verified
  - Client reconnection tested

- ☑ **Monitoring**
  - Cluster status monitoring configured
  - PostgreSQL log monitoring
  - Disk space alerts (especially for WAL)
  - Replication lag alerts

---

## Appendix A: Migrating from Bare-Metal to Container Mode

> ⚠️ **EXPERIMENTAL FEATURE**
>
> Container mode is experimental. See section 2.6.2 for details and recommendations.

**This section is for existing clusters migrating from bare-metal to container mode.**

If you're setting up a new cluster, you don't need this section.

---

### Overview

Migrating from bare-metal to container mode is straightforward since v1.6.7+ uses the `--user` flag to run containers as the host's postgres user.

**Key Principle**: Container will run as whatever user owns PGDATA, so keep ownership unchanged.

### Prerequisites

- Existing bare-metal cluster running pgtwin
- Podman or Docker installed on both nodes
- pgtwin v1.6.7+ and container library installed

### Migration Procedure

**Step 1: Identify Current PostgreSQL User**

```bash
# Check current PGDATA ownership
ls -ld /var/lib/pgsql/data
# Example: drwx------ 1 postgres postgres 566 Dec 11 09:53 /var/lib/pgsql/data

# Get username
PGUSER=$(stat -c '%U' /var/lib/pgsql/data)
echo "Current PostgreSQL user: $PGUSER"
```

**Step 2: Stop Cluster Resources**

```bash
# On node 1
sudo crm resource stop postgres-clone

# Wait for all resources to stop
watch -n 2 'sudo crm status'
# Wait until: "Stopped: [ psql1 psql2 ]"
```

**Step 3: Verify PostgreSQL is Stopped**

```bash
# On both nodes
sudo systemctl status postgresql
# Should show: "inactive (dead)"

ps aux | grep postgres | grep -v grep
# Should return nothing
```

**Step 4: Backup Configuration (Recommended)**

```bash
# On node 1 - save current config
sudo crm configure show postgres-db > /tmp/postgres-db-backup.crm
```

**Step 5: Install Container Runtime and Library** (Both Nodes)

```bash
# Install Podman
sudo zypper install podman

# Install container library
sudo cp pgtwin-container-lib.sh /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
sudo chmod 644 /usr/lib/ocf/lib/heartbeat/pgtwin-container-lib.sh
```

**Step 6: Update Cluster Configuration**

```bash
# On node 1 - add container mode parameters
# Get current config
sudo crm configure edit postgres-db

# Add these parameters:
# container_mode="true"
# pg_major_version="17"
# container_name="postgres-ha"
# pguser="postgres"  ← MUST match $PGUSER from Step 1!

# Alternative: Use crm configure primitive to rebuild
```

**Example updated configuration**:

```bash
sudo crm configure primitive postgres-db pgtwin \
  params \
    container_mode="true" \
    pg_major_version="17" \
    container_name="postgres-ha" \
    pguser="postgres" \  # ← Matches bare-metal username
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
    backup_before_basebackup="true" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    slot_name="ha_slot" \
  op start timeout="120s" interval="0s" \
  op stop timeout="120s" interval="0s" \
  op monitor interval="8s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted" \
  op promote timeout="120s" interval="0s" \
  op demote timeout="120s" interval="0s" \
  op notify timeout="90s" interval="0s"
```

**⚠️ CRITICAL**: The `pguser` parameter **MUST** match the username that owns PGDATA (from Step 1).

**Step 7: Start Cluster Resources**

```bash
# On node 1
sudo crm resource start postgres-clone

# Monitor startup
watch -n 2 'sudo crm status'

# Watch logs
sudo journalctl -u pacemaker -f
```

**Expected log output**:
```
INFO: Detected host 'postgres' UID:GID = 26:26
INFO: ✓ PGDATA ownership correct (postgres 26:26)
INFO: ✓ Startup validation passed: Ownership correct
INFO: Creating PostgreSQL container: postgres-ha
INFO: Container postgres-ha started successfully
INFO: PostgreSQL started successfully
```

**Step 8: Verify Container Mode Operation**

```bash
# Check containers are running
sudo podman ps
# Should show postgres-ha container

# Check PostgreSQL is accessible
sudo podman exec postgres-ha psql -U postgres -c "SELECT version();"

# Check replication (on primary)
sudo podman exec postgres-ha psql -U postgres -x -c "SELECT * FROM pg_stat_replication;"

# Verify cluster status
sudo crm status
# Should show: Promoted: [ psql1 ], Unpromoted: [ psql2 ]
```

**Step 9: Test Failover**

```bash
# Test manual failover
sudo crm resource move postgres-clone psql2
watch -n 2 'sudo crm status'

# Clear constraint
sudo crm resource clear postgres-clone
```

### Migration Complete!

**What changed**:
- PostgreSQL now runs in containers
- File ownership unchanged (still owned by postgres user)
- Container runs as postgres user (via `--user` flag)
- No data migration needed
- Same security model

### Rollback Plan

If needed, revert to bare-metal:

```bash
# Stop cluster
sudo crm resource stop postgres-clone

# Restore original config
sudo crm configure load update /tmp/postgres-db-backup.crm

# Start cluster
sudo crm resource start postgres-clone
```

---

## Advanced: Multi-Instance Setup (Container Mode)

> ⚠️ **EXPERIMENTAL FEATURE**
>
> Container mode is experimental. See section 2.6.2 for details and recommendations.
> Multi-instance setups add additional complexity and should be tested thoroughly.

**Running multiple PostgreSQL databases on the same hardware with different users.**

### Why Multi-Instance?

- Run production, staging, and development databases on one pair of servers
- Resource isolation via different system users
- Separate credentials (.pgpass files) per instance
- Different PostgreSQL versions possible (change `pg_major_version`)

### Architecture

Each instance requires:
- **Different host user** (postgres, postgres1, postgres2, etc.)
- **Different HOME directory** (/var/lib/pgsql, /var/lib/pgsql1, /var/lib/pgsql2)
- **Different PGDATA directory**
- **Different port** (5432, 5433, 5434, etc.)
- **Different container name**

| Instance | Host User | HOME | PGDATA | Port | Container |
|----------|-----------|------|--------|------|-----------|
| Production | postgres (UID 476) | /var/lib/pgsql | /var/lib/pgsql/data | 5432 | postgres-ha |
| Staging | postgres1 (UID 475) | /var/lib/pgsql1 | /var/lib/pgsql1/data | 5433 | postgres1-ha |
| Development | postgres2 (UID 555) | /var/lib/pgsql2 | /var/lib/pgsql2/data | 5434 | postgres2-ha |

### Setup Steps

#### 1. Create Additional Users

On **both nodes**:

```bash
# Create postgres1 user for staging instance
groupadd -r postgres1
mkdir -p /var/lib/pgsql1
useradd -r -g postgres1 -d /var/lib/pgsql1 -s /bin/bash postgres1
chown postgres1:postgres1 /var/lib/pgsql1

# Create postgres2 user for development instance
groupadd -r postgres2
mkdir -p /var/lib/pgsql2
useradd -r -g postgres2 -d /var/lib/pgsql2 -s /bin/bash postgres2
chown postgres2:postgres2 /var/lib/pgsql2
```

**IMPORTANT**: On standby node, create users with **SAME UID** as primary:

```bash
# On primary, get UIDs
ssh root@psql1 "echo postgres=$(id -u postgres) postgres1=$(id -u postgres1) postgres2=$(id -u postgres2)"
# Output: postgres=476 postgres1=475 postgres2=555

# On standby, create with matching UIDs
useradd -r -u 476 -g postgres -d /var/lib/pgsql -s /bin/bash postgres
useradd -r -u 475 -g postgres1 -d /var/lib/pgsql1 -s /bin/bash postgres1
useradd -r -u 555 -g postgres2 -d /var/lib/pgsql2 -s /bin/bash postgres2
```

#### 2. Initialize Each Instance (Primary Node)

```bash
# Instance 1: Production (default postgres user)
sudo ./container-mode-primary-init.sh

# Instance 2: Staging (postgres1 user)
sudo PGUSER=postgres1 PGDATA=/var/lib/pgsql1/data \
     REPLICATION_PASSWORD=staging123 \
     ./container-mode-primary-init.sh

# Instance 3: Development (postgres2 user)
sudo PGUSER=postgres2 PGDATA=/var/lib/pgsql2/data \
     REPLICATION_PASSWORD=dev123 \
     ./container-mode-primary-init.sh
```

Each instance creates its own .pgpass file:
- `/var/lib/pgsql/.pgpass` (production)
- `/var/lib/pgsql1/.pgpass` (staging)
- `/var/lib/pgsql2/.pgpass` (development)

#### 3. Copy .pgpass Files to Standby

```bash
# Copy each .pgpass file separately
scp root@psql1:/var/lib/pgsql/.pgpass root@psql2:/var/lib/pgsql/
scp root@psql1:/var/lib/pgsql1/.pgpass root@psql2:/var/lib/pgsql1/
scp root@psql1:/var/lib/pgsql2/.pgpass root@psql2:/var/lib/pgsql2/

# Fix permissions on standby
ssh root@psql2 "chown postgres:postgres /var/lib/pgsql/.pgpass && chmod 600 /var/lib/pgsql/.pgpass"
ssh root@psql2 "chown postgres1:postgres1 /var/lib/pgsql1/.pgpass && chmod 600 /var/lib/pgsql1/.pgpass"
ssh root@psql2 "chown postgres2:postgres2 /var/lib/pgsql2/.pgpass && chmod 600 /var/lib/pgsql2/.pgpass"
```

#### 4. Configure Pacemaker Resources

Create separate resources for each instance:

```bash
# Production instance (port 5432)
sudo crm configure primitive postgres-db pgtwin \
  params \
    container_mode="true" \
    pg_major_version="17" \
    container_name="postgres-ha" \
    pguser="postgres" \
    pgdata="/var/lib/pgsql/data" \
    pgport="5432" \
    pgpassfile="/var/lib/pgsql/.pgpass" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted"

# Staging instance (port 5433)
sudo crm configure primitive postgres1-db pgtwin \
  params \
    container_mode="true" \
    pg_major_version="17" \
    container_name="postgres1-ha" \
    pguser="postgres1" \
    pgdata="/var/lib/pgsql1/data" \
    pgport="5433" \
    pgpassfile="/var/lib/pgsql1/.pgpass" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted"

# Development instance (port 5434)
sudo crm configure primitive postgres2-db pgtwin \
  params \
    container_mode="true" \
    pg_major_version="17" \
    container_name="postgres2-ha" \
    pguser="postgres2" \
    pgdata="/var/lib/pgsql2/data" \
    pgport="5434" \
    pgpassfile="/var/lib/pgsql2/.pgpass" \
    rep_mode="sync" \
    node_list="psql1 psql2" \
  op start timeout="120s" interval="0" \
  op stop timeout="120s" interval="0" \
  op monitor interval="10s" timeout="60s" role="Unpromoted" \
  op monitor interval="3s" timeout="60s" role="Promoted"

# Create clones (one per instance)
sudo crm configure clone postgres-clone postgres-db \
  meta promotable="true" target-role="Started"

sudo crm configure clone postgres1-clone postgres1-db \
  meta promotable="true" target-role="Started"

sudo crm configure clone postgres2-clone postgres2-db \
  meta promotable="true" target-role="Started"
```

### How Container UID Mapping Works

The container user is always named "postgres", but its UID changes to match the host user:

```
Host: postgres1 (UID 475)  →  Container: postgres (UID 475)
Host: postgres2 (UID 555)  →  Container: postgres (UID 555)
```

This is handled automatically by `pgtwin_fix_container_user_id()` function which:
1. Detects host user UID:GID
2. Modifies container's `/etc/passwd` and `/etc/group`
3. Changes postgres user UID:GID to match host

**No permission issues** - Container postgres (UID 475) can access files owned by host postgres1 (UID 475).

### Key Points

✅ **Separate HOME directories** - Each user has own .pgpass file
✅ **Automatic UID matching** - Container postgres UID changes to match host user
✅ **No duplicate users** - Container user always named "postgres"
✅ **Port isolation** - Each instance uses different port
✅ **Resource isolation** - Different system users prevent cross-contamination

---

## Next Steps

1. **Automatic Standby Initialization**: See FEATURE_AUTO_INITIALIZATION.md for details on auto-init feature
2. **Administration Commands**: See CHEATSHEET.md for complete command reference
3. **Architecture Details**: See README.md for design decisions and features

---

## Quick Reference

| Task | Command |
|------|---------|
| Check status | `sudo crm status` |
| Check detailed status | `sudo crm_mon -1Afr` |
| Manual failover | `sudo crm resource move postgres-clone <node>` |
| Clear constraints | `sudo crm resource clear postgres-clone` |
| Check replication | `sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"` |
| Check configuration | `sudo crm configure show` |
| Pacemaker logs | `sudo journalctl -u pacemaker -f` |
| PostgreSQL logs | `sudo tail -f /var/lib/pgsql/data/log/postgresql-*.log` |

---

**pgtwin** - PostgreSQL Twin: Two-Node HA Made Simple

For more information, visit: https://github.com/azouhr/pgtwin
