# Quickstart: 2-Node PostgreSQL HA Cluster with Dual Corosync Rings

> ⚠️ **EXPERIMENTAL FEATURE**
> 
> This guide describes an experimental configuration using dual Corosync network rings
> as an alternative to SBD-based fencing. While technically sound, this configuration
> has received limited production testing compared to the standard SBD-based setup.
> 
> **Recommendations**:
> - ✅ Use for testing and evaluation
> - ✅ Use in environments without shared storage
> - ⚠️ **For production**: Prefer SBD-based fencing (see main QUICKSTART.md)
> - ⚠️ Requires careful network configuration and testing
> - ⚠️ Both network paths must be truly independent
> 
> **Status**: Experimental - Feedback Welcome
> **Last Updated**: 2025-12-17

---

**Author**: High Availability PostgreSQL with pgtwin
**Date**: 2025-12-09
**Topic**: Dual-Ring Corosync for Network Redundancy (Alternative to SBD)

---

## Overview

This guide demonstrates how to set up a highly available 2-node PostgreSQL cluster using **dual Corosync network rings** instead of SBD (Storage-Block Device) for split-brain protection. This approach provides network redundancy without requiring shared storage.

### Why Dual Rings?

**Traditional SBD Approach**:
- Requires shared storage device (iSCSI, FC, shared disk)
- Additional infrastructure and complexity
- Single point of failure if storage fails

**Dual Ring Approach**:
- Two independent network paths between nodes
- No shared storage required
- Better resilience to network failures
- Direct cable connection provides dedicated heartbeat

### Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                     Application Layer                       │
│                (Connects to VIP: 192.168.1.20)              │
└──────────────────────┬──────────────────────────────────────┘
                       │
              PostgreSQL (TCP 5432)
                       │
┌──────────────────────┴──────────────────────────────────────┐
│              PostgreSQL HA Cluster (pgtwin)                 │
│                                                             │
│  ┌───────────────────┐              ┌───────────────────┐   │
│  │   psql1           │              │   psql2           │   │
│  │   192.168.1.10    │              │   192.168.1.11    │   │
│  │                   │              │                   │   │
│  │   ┌─────────┐     │              │     ┌─────────┐   │   │
│  │   │  eth0   │─────┼──────────────┼─────│  eth0   │   │   │  Ring 0
│  │   │(public) │     │   Network    │     │(public) │   │   │  (192.168.1.0/24)
│  │   └─────────┘     │   Switch     │     └─────────┘   │   │
│  │                   │              │                   │   │
│  │   ┌─────────┐     │              │     ┌─────────┐   │   │
│  │   │  eth1   │─────┼──────────────┼─────│  eth1   │   │   │  Ring 1
│  │   │(direct) │═════╪═ Direct Cable══════│(direct) │   │   │  (10.10.10.0/24)
│  │   └─────────┘     │              │     └─────────┘   │   │
│  │                   │              │                   │   │
│  │  Corosync/        │              │  Corosync/        │   │
│  │  Pacemaker        │              │  Pacemaker        │   │
│  │  pgtwin OCF       │              │  pgtwin OCF       │   │
│  └───────────────────┘              └───────────────────┘   │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

**Network Configuration**:
- **Ring 0 (eth0)**: Public network via switch (192.168.1.0/24)
- **Ring 1 (eth1)**: Direct crossover cable (10.10.10.0/24)
- **VIP**: 192.168.1.20 (floats between nodes)
- **External Gateway**: 192.168.1.1 (for network path validation)

---

## Prerequisites

### Hardware Requirements

**Each Node Needs**:
- 2× Network Interface Cards (NICs)
  - eth0: Connected to network switch (for client access)
  - eth1: Direct connection to other node (crossover cable or direct link)
- Minimum 2 CPU cores
- Minimum 4 GB RAM (8 GB recommended)
- Minimum 20 GB disk space

**Network Equipment**:
- 1× Network switch (for Ring 0)
- 1× Crossover cable or direct connection (for Ring 1)
  - If NICs support auto-MDI/MDIX, regular Ethernet cable works
  - Otherwise, use proper crossover cable

### Software Requirements

- openSUSE Tumbleweed or SUSE Linux Enterprise 15 SP5+
- PostgreSQL 17.x
- Pacemaker 3.0+
- Corosync 3.0+
- pgtwin v1.6.6+

---

## Design Philosophy: Network Partitioning and Replication

### Assumptions and Failure Domains

**Network Partition Between Nodes**:

With dual Corosync rings, network partition between nodes requires **both rings to fail simultaneously**. This is considered a **double failure** outside the design scope of this configuration.

- **Single ring failure** → Corosync continues on remaining ring ✅
- **Both rings fail (nodes alive, communication lost)** → Network isolation, quorum lost (not designed for)
  - ⚠️ **Important**: This means both communication paths fail while **both nodes remain operational**
  - This is a network/communication failure, not a node crash or hardware failure
- **Therefore**: If both nodes are healthy and reachable, Corosync ALWAYS has connectivity

### The Real Challenge: Partial Network Partition

The actual problem this configuration solves is **partial network partition**:

**Scenario**: One datacenter (psql1) loses external connectivity (Ring 0) but maintains cluster communication (Ring 1):
- **Corosync**: ✅ Still connected via Ring 1 (both nodes communicate)
- **Pacemaker**: ✅ Cluster operational, can perform migrations
- **PostgreSQL Replication**: ❌ Cannot connect (uses Ring 0 addresses in `primary_conninfo`)
- **Synchronous Replication**: ❌ Would block writes if enabled without standby connection

### Solution: Connectivity-Dependent Standby Placement

**Design Decision**: Prevent standby (unpromoted) resource from running on nodes without external connectivity.

**How It Works**:

1. **Ping monitoring** detects loss of external connectivity (Ring 0) on a node
2. **Location constraint** prevents unpromoted role from running on that node (score: -inf)
3. **Pacemaker** stops the standby resource on the disconnected node
4. **pgtwin notify system** receives `post-stop` notification
5. **Sync replication** automatically disabled on primary → **writes no longer block**
6. **When connectivity restored**: Standby auto-starts, sync replication re-enabled

**Why This Is Superior to Multi-Host primary_conninfo**:

| Approach | Code Changes | Write Blocking Risk | Recovery | Complexity |
|----------|--------------|---------------------|----------|------------|
| **Connectivity-Dependent Standby** | None (Pacemaker constraints) | No (auto-disabled) | Automatic | Low |
| Multi-Host primary_conninfo | Modify pgtwin | Possible (until timeout) | Manual | Medium |

**Benefits**:
- ✅ **No code changes** - uses existing pgtwin v1.6.6 notify support
- ✅ **Fail-fast** - immediate stop instead of connection timeout retries
- ✅ **No write blocking** - sync auto-disabled when standby stops
- ✅ **Automatic recovery** - standby auto-starts when connectivity restored
- ✅ **Pacemaker-native** - uses constraint system as designed
- ✅ **Clean separation** - promoted can run anywhere, unpromoted needs connectivity

### Fencing and Split-Brain Protection

**No STONITH Required**: With dual rings preventing network partition between nodes, traditional fencing (STONITH) is not required for split-brain protection.

**Optional Watchdog**: For protection against software hangs (Pacemaker/PostgreSQL process freeze), watchdog-based fencing can be optionally configured:
```bash
property cib-bootstrap-options: \
    stonith-enabled=true \
    have-watchdog=true
```

---

## Step 1: Network Configuration

### Node 1 (psql1)

#### Check Existing Connections

```bash
# List current connections
nmcli connection show

# Identify the connection names for eth0 and eth1
# They might be named "Wired connection 1", "eth0", "System eth0", etc.
```

#### Configure eth0 (Public Network)

```bash
# Configure eth0 with static IP and gateway
sudo nmcli connection modify eth0 \
    ipv4.method manual \
    ipv4.addresses 192.168.1.10/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns "8.8.8.8 8.8.4.4" \
    connection.autoconnect yes

# Apply configuration
sudo nmcli connection up eth0
```

**Note**: Replace `eth0` with the actual connection name if different (e.g., "Wired connection 1").

#### Configure eth1 (Direct Link)

```bash
# Configure eth1 WITHOUT gateway (prevent routing conflicts)
sudo nmcli connection modify eth1 \
    ipv4.method manual \
    ipv4.addresses 10.10.10.1/24 \
    ipv4.never-default yes \
    connection.autoconnect yes

# Apply configuration
sudo nmcli connection up eth1
```

**Critical**: The `ipv4.never-default yes` setting prevents eth1 from creating a default route, avoiding conflicts with the eth0 gateway.

#### Verify Configuration

```bash
# Check IP addresses
ip addr show eth0
ip addr show eth1

# Verify routing table (should have only ONE default gateway via eth0)
ip route show
# Expected: default via 192.168.1.1 dev eth0
#           10.10.10.0/24 dev eth1 (no default route)
```

---

### Node 2 (psql2)

#### Check Existing Connections

```bash
# List current connections
nmcli connection show
```

#### Configure eth0 (Public Network)

```bash
# Configure eth0 with static IP and gateway
sudo nmcli connection modify eth0 \
    ipv4.method manual \
    ipv4.addresses 192.168.1.11/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns "8.8.8.8 8.8.4.4" \
    connection.autoconnect yes

# Apply configuration
sudo nmcli connection up eth0
```

#### Configure eth1 (Direct Link)

```bash
# Configure eth1 WITHOUT gateway (prevent routing conflicts)
sudo nmcli connection modify eth1 \
    ipv4.method manual \
    ipv4.addresses 10.10.10.2/24 \
    ipv4.never-default yes \
    connection.autoconnect yes

# Apply configuration
sudo nmcli connection up eth1
```

#### Verify Configuration

```bash
# Check IP addresses
ip addr show eth0
ip addr show eth1

# Verify routing table (should have only ONE default gateway via eth0)
ip route show
# Expected: default via 192.168.1.1 dev eth0
#           10.10.10.0/24 dev eth1 (no default route)
```

---

### Troubleshooting: Removing Unwanted Default Gateway

If you accidentally configured eth1 with a gateway (or NetworkManager auto-configured one), you'll end up with **two default routes**. This causes routing conflicts and must be fixed.

#### Detecting the Problem

```bash
# Check routing table
ip route show

# Problem: You see TWO default routes like this:
# default via 192.168.1.1 dev eth0 proto static metric 100
# default via 10.10.10.1 dev eth1 proto static metric 101  ← UNWANTED!
# 10.10.10.0/24 dev eth1 proto kernel scope link src 10.10.10.1
# 192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10
```

#### Solution: Delete the Second Default Gateway

**Method 1: Remove gateway from eth1 connection permanently**

```bash
# Remove the gateway setting from eth1 connection
sudo nmcli connection modify eth1 ipv4.gateway ""

# Prevent future default routes on this connection
sudo nmcli connection modify eth1 ipv4.never-default yes

# Reactivate the connection to apply changes
sudo nmcli connection down eth1
sudo nmcli connection up eth1

# Verify: Should now have only ONE default route
ip route show
# Expected: default via 192.168.1.1 dev eth0 (only one!)
```

**Method 2: Temporarily delete the route (not persistent across reboots)**

```bash
# Find the unwanted default route
ip route show | grep "^default"

# Delete the eth1 default route (replace 10.10.10.1 with your gateway)
sudo ip route del default via 10.10.10.1 dev eth1

# Verify
ip route show
# Expected: Only one default route via eth0
```

**⚠️ Note**: Method 2 is temporary - the route will come back after reboot or connection restart. Always use Method 1 for permanent fix.

#### Why This Matters

Having two default gateways causes:
- **Unpredictable routing** - traffic may go out the wrong interface
- **Failed connections** - packets sent via Ring 1 (direct link) can't reach internet
- **Application issues** - PostgreSQL and cluster communication may fail
- **Monitoring failures** - ping-gateway resource may ping via wrong interface

**Always ensure only ONE default gateway** (via Ring 0/eth0 for external connectivity).

---

### Creating Connections from Scratch (If Needed)

If connections don't exist for your interfaces, create them:

**On psql1**:
```bash
# Create connection for eth0 (public network)
sudo nmcli connection add \
    type ethernet \
    con-name eth0 \
    ifname eth0 \
    ipv4.method manual \
    ipv4.addresses 192.168.1.10/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns "8.8.8.8 8.8.4.4" \
    connection.autoconnect yes

# Create connection for eth1 (direct link, NO gateway)
sudo nmcli connection add \
    type ethernet \
    con-name eth1 \
    ifname eth1 \
    ipv4.method manual \
    ipv4.addresses 10.10.10.1/24 \
    ipv4.never-default yes \
    connection.autoconnect yes

# Activate both connections
sudo nmcli connection up eth0
sudo nmcli connection up eth1
```

**On psql2**:
```bash
# Create connection for eth0 (public network)
sudo nmcli connection add \
    type ethernet \
    con-name eth0 \
    ifname eth0 \
    ipv4.method manual \
    ipv4.addresses 192.168.1.11/24 \
    ipv4.gateway 192.168.1.1 \
    ipv4.dns "8.8.8.8 8.8.4.4" \
    connection.autoconnect yes

# Create connection for eth1 (direct link, NO gateway)
sudo nmcli connection add \
    type ethernet \
    con-name eth1 \
    ifname eth1 \
    ipv4.method manual \
    ipv4.addresses 10.10.10.2/24 \
    ipv4.never-default yes \
    connection.autoconnect yes

# Activate both connections
sudo nmcli connection up eth0
sudo nmcli connection up eth1
```

---

### Test Network Connectivity

From **psql1**:
```bash
# Test Ring 0 (public network)
ping -c 3 192.168.1.11

# Test Ring 1 (direct link)
ping -c 3 10.10.10.2

# Test external connectivity (via default gateway on eth0)
ping -c 3 192.168.1.1
ping -c 3 8.8.8.8

# CRITICAL: Verify routing table (must have only ONE default gateway)
ip route show
```

**Expected routing table** on psql1:
```
default via 192.168.1.1 dev eth0 proto static metric 100
10.10.10.0/24 dev eth1 proto kernel scope link src 10.10.10.1 metric 101
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.10 metric 100
```

From **psql2**:
```bash
# Test Ring 0 (public network)
ping -c 3 192.168.1.10

# Test Ring 1 (direct link)
ping -c 3 10.10.10.1

# Test external connectivity (via default gateway on eth0)
ping -c 3 192.168.1.1
ping -c 3 8.8.8.8

# CRITICAL: Verify routing table (must have only ONE default gateway)
ip route show
```

**Expected routing table** on psql2:
```
default via 192.168.1.1 dev eth0 proto static metric 100
10.10.10.0/24 dev eth1 proto kernel scope link src 10.10.10.2 metric 101
192.168.1.0/24 dev eth0 proto kernel scope link src 192.168.1.11 metric 100
```

**Expected Results**:
- ✅ All pings should succeed with low latency (< 1ms for direct link)
- ✅ Only ONE default route via eth0 (Ring 0)
- ✅ NO default route via eth1 (Ring 1) - thanks to `ipv4.never-default yes`
- ✅ External connectivity works (8.8.8.8 reachable)

---

## Step 2: Hostname and DNS Configuration

### Configure Hostnames

On **psql1**:
```bash
sudo hostnamectl set-hostname psql1
```

On **psql2**:
```bash
sudo hostnamectl set-hostname psql2
```

### Configure /etc/hosts (Both Nodes)

```bash
# /etc/hosts
127.0.0.1   localhost

# Ring 0 (Public Network)
192.168.1.10    psql1
192.168.1.11    psql2

# Ring 1 (Direct Link)
10.10.10.1      psql1-direct
10.10.10.2      psql2-direct

# Virtual IP (will be managed by cluster)
192.168.1.20    postgres-vip
```

Test resolution:
```bash
ping -c 2 psql1
ping -c 2 psql2
ping -c 2 psql1-direct
ping -c 2 psql2-direct
```

---

## Step 3: Firewall Configuration

### Configure Firewall Rules (Both Nodes)

```bash
# Corosync communication (Ring 0 - public network)
sudo firewall-cmd --permanent --add-port=5405/udp  # Corosync multicast
sudo firewall-cmd --permanent --add-port=5404/udp  # Corosync multicast (alternative)

# Corosync communication (Ring 1 - direct link)
# Note: Traffic on eth1 should be allowed by default (not going through firewall)
# But if using firewalld zones, ensure direct link interface is in trusted zone

# Pacemaker communication
sudo firewall-cmd --permanent --add-port=2224/tcp  # pcsd
sudo firewall-cmd --permanent --add-port=3121/tcp  # Pacemaker
sudo firewall-cmd --permanent --add-port=21064/tcp # DLM (if used)

# PostgreSQL
sudo firewall-cmd --permanent --add-port=5432/tcp

# Reload firewall
sudo firewall-cmd --reload
```

**Alternative**: Put direct link interface in trusted zone:
```bash
# Get current zone for eth1
sudo firewall-cmd --get-zone-of-interface=eth1

# Move eth1 to trusted zone (no filtering)
sudo firewall-cmd --permanent --zone=trusted --add-interface=eth1
sudo firewall-cmd --reload
```

---

## Step 4: Install Cluster Software

### Install Packages (Both Nodes)

```bash
# Install Pacemaker, Corosync, and cluster tools
sudo zypper install -y \
    pacemaker \
    corosync \
    crmsh \
    resource-agents \
    fence-agents

# Install PostgreSQL 18
sudo zypper install -y \
    postgresql18 \
    postgresql18-server \
    postgresql18-contrib
```

### Install pgtwin Resource Agent (Both Nodes)

```bash
# Copy pgtwin OCF agent
sudo cp /path/to/pgtwin /usr/lib/ocf/resource.d/heartbeat/pgtwin
sudo chmod 755 /usr/lib/ocf/resource.d/heartbeat/pgtwin

# Verify installation
sudo ocf-tester -n pgtwin -o pgdata=/tmp/test || echo "Test expected to fail without valid PGDATA"
```

---

## Step 5: Configure Corosync (Dual Ring Setup)

### Create Corosync Configuration (Both Nodes)

Create `/etc/corosync/corosync.conf`:

```bash
# /etc/corosync/corosync.conf
totem {
    version: 2
    cluster_name: postgres-ha
    transport: knet
    crypto_cipher: aes256
    crypto_hash: sha256

    # Timeout and retransmit configuration
    # These values are from openSUSE defaults and provide stable operation
    token: 5000                              # Token timeout (5 seconds)
                                             # Time before a node is declared dead
                                             # Lower = faster failover, higher = more stable

    join: 60                                 # Join timeout (60ms)
                                             # Timeout for join messages during node addition

    max_messages: 20                         # Maximum messages in transit
                                             # Prevents message queue overflow

    token_retransmits_before_loss_const: 10  # Token retransmit threshold
                                             # Number of failed token sends before declaring
                                             # node lost (10 × token = 50 seconds total)

    # Dual ring configuration
    interface {
        ringnumber: 0
        mcastport: 5405
    }

    interface {
        ringnumber: 1
        mcastport: 5407
    }
}

nodelist {
    node {
        ring0_addr: 192.168.1.10
        ring1_addr: 10.10.10.1
        name: psql1
        nodeid: 1
    }

    node {
        ring0_addr: 192.168.1.11
        ring1_addr: 10.10.10.2
        name: psql2
        nodeid: 2
    }
}

quorum {
    provider: corosync_votequorum
    two_node: 1
    wait_for_all: 1
}

logging {
    to_logfile: yes
    logfile: /var/log/cluster/corosync.log
    to_syslog: yes
    timestamp: on
}
```

**Key Configuration Points**:

1. **`transport: knet`**: Modern Kronosnet transport (supports multiple links)
2. **Timeout parameters** (openSUSE defaults):
   - **`token: 5000`**: 5-second token timeout - balance between failover speed and stability
   - **`join: 60`**: 60ms join timeout - how long to wait for join messages
   - **`max_messages: 20`**: Maximum messages in transit - prevents queue overflow
   - **`token_retransmits_before_loss_const: 10`**: Retransmit threshold before declaring node lost
   - **Combined effect**: Node declared dead after ~50 seconds of token loss (10 retransmits × 5s token)
3. **Two interfaces**: Ring 0 (public) and Ring 1 (direct)
4. **Different mcastports**: 5405 for Ring 0, 5407 for Ring 1
5. **nodelist**: Explicit node definitions with both ring addresses
6. **`two_node: 1`**: Special quorum handling for 2-node clusters
7. **`wait_for_all: 1`**: Wait for all nodes before forming quorum (safer for 2-node)

**Why These Timeout Values?**

The openSUSE defaults provide a good balance:
- **Fast enough**: ~50 seconds to detect complete node failure
- **Stable enough**: Won't trigger false positives from brief network hiccups
- **Dual-ring aware**: With two rings, transient issues on one ring won't cause problems
- **Production tested**: These values are used in many production SUSE HA clusters

**Tuning Considerations**:
- **Faster failover**: Reduce `token` to 3000ms (3s), but may cause false positives
- **More stable**: Increase `token` to 10000ms (10s), slower failover but more tolerant
- **Dual-ring environments**: Can use lower values since you have redundant paths
- **WAN clusters**: Increase values significantly (token: 30000, etc.)

### Create Corosync Authkey (Node 1 Only)

```bash
# Generate authentication key on psql1
sudo corosync-keygen -l
```

**Note**: This generates `/etc/corosync/authkey`. Takes several minutes.

### Copy Authkey to Node 2

From **psql1**:
```bash
sudo scp /etc/corosync/authkey root@psql2:/etc/corosync/authkey
```

On **psql2**:
```bash
sudo chmod 400 /etc/corosync/authkey
sudo chown root:root /etc/corosync/authkey
```

### Verify Corosync Configuration (Both Nodes)

```bash
# Check configuration syntax
sudo corosync-cfgtool -s

# Check if configuration is valid
sudo corosync -t
```

---

## Step 6: Start Corosync and Pacemaker

### Start Services (Both Nodes)

```bash
# Enable and start Corosync
sudo systemctl enable corosync
sudo systemctl start corosync

# Wait 10 seconds for Corosync to stabilize
sleep 10

# Check Corosync status
sudo corosync-cfgtool -s

# Enable and start Pacemaker
sudo systemctl enable pacemaker
sudo systemctl start pacemaker
```

### Verify Cluster Formation

```bash
# Check cluster membership (should show 2 nodes)
sudo crm status

# Check Corosync ring status (both rings should be active)
sudo corosync-cfgtool -s

# Check quorum
sudo corosync-quorumtool
```

**Expected Output** (corosync-cfgtool -s):
```
Local node ID 1, transport knet
LINK ID 0 udp
        addr    = 192.168.1.10
        status:
                nodeid:          1:     localhost
                nodeid:          2:     connected
LINK ID 1 udp
        addr    = 10.10.10.1
        status:
                nodeid:          1:     localhost
                nodeid:          2:     connected
```

**Expected Output** (crm status):
```
Cluster Summary:
  * Stack: corosync
  * Current DC: psql1
  * Last updated: ...
  * 2 nodes configured
  * 0 resource instances configured

Node List:
  * Online: [ psql1 psql2 ]
```

---

## Step 7: Configure PostgreSQL

This guide uses the provided `github/postgresql.custom.conf` file which contains all required PostgreSQL settings for HA operation with pgtwin. No modifications are needed to this file.

### Initialize PostgreSQL (Node 1 Only - Primary)

On **psql1**:
```bash
# Initialize database
sudo -u postgres initdb -D /var/lib/pgsql/data

# Copy the provided PostgreSQL HA configuration
sudo cp /path/to/pgtwin/github/postgresql.custom.conf /var/lib/pgsql/data/postgresql.custom.conf
sudo chown postgres:postgres /var/lib/pgsql/data/postgresql.custom.conf

# Include custom config in main postgresql.conf
sudo -u postgres bash -c "echo \"include = 'postgresql.custom.conf'\" >> /var/lib/pgsql/data/postgresql.conf"

# Configure pg_hba.conf for replication
sudo -u postgres tee -a /var/lib/pgsql/data/pg_hba.conf <<EOF

# Replication connections
host    replication     replicator      192.168.1.0/24       scram-sha-256
host    postgres        replicator      192.168.1.0/24       scram-sha-256
EOF

# Start PostgreSQL manually (temporary)
sudo -u postgres pg_ctl -D /var/lib/pgsql/data start

# Create replication user
sudo -u postgres psql <<EOF
CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD 'SecurePassword123';
GRANT pg_read_all_data TO replicator;
GRANT EXECUTE ON FUNCTION pg_ls_dir(text, boolean, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_stat_file(text, boolean) TO replicator;
GRANT EXECUTE ON FUNCTION pg_read_binary_file(text) TO replicator;
GRANT EXECUTE ON FUNCTION pg_read_binary_file(text, bigint, bigint, boolean) TO replicator;
EOF

# Stop PostgreSQL (cluster will manage it)
sudo -u postgres pg_ctl -D /var/lib/pgsql/data stop
```

### Configure .pgpass (Both Nodes)

On **both nodes**:
```bash
# Create .pgpass file
# Format: hostname:port:database:username:password
#
# NOTE: Both hostnames AND IP addresses are included for redundancy
# This ensures credentials work even if DNS/name resolution fails
#
# IMPORTANT: Only Ring 0 (public network) addresses are used
# Ring 1 is dedicated to Corosync cluster communication only
sudo -u postgres tee /var/lib/pgsql/.pgpass <<EOF
# Replication database entries (for streaming replication)
psql1:5432:replication:replicator:SecurePassword123
psql2:5432:replication:replicator:SecurePassword123
192.168.1.10:5432:replication:replicator:SecurePassword123
192.168.1.11:5432:replication:replicator:SecurePassword123

# Postgres database entries (required for pg_rewind and admin operations)
psql1:5432:postgres:replicator:SecurePassword123
psql2:5432:postgres:replicator:SecurePassword123
192.168.1.10:5432:postgres:replicator:SecurePassword123
192.168.1.11:5432:postgres:replicator:SecurePassword123
EOF

# Set correct permissions (CRITICAL)
sudo chmod 600 /var/lib/pgsql/.pgpass
sudo chown postgres:postgres /var/lib/pgsql/.pgpass
```

**Why Both Names and IPs?**
- **Redundancy**: Works even if /etc/hosts or DNS fails
- **Troubleshooting**: Easier to debug connection issues
- **Auto-initialization**: pgtwin can discover and connect regardless of hostname resolution

**Note**: Only Ring 0 (192.168.1.x) addresses are used for PostgreSQL. Ring 1 (10.10.10.x) is exclusively for Corosync heartbeat communication

### Prepare Node 2 (Empty PGDATA for Auto-Init)

On **psql2**:
```bash
# Create empty PGDATA directory
sudo mkdir -p /var/lib/pgsql/data
sudo chown postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data

# That's it! pgtwin will auto-initialize this node
```

---

## Step 8: Configure Pacemaker Cluster

**Quick Start Option**: You can use the prepared `pgsql-resource-config.crm` file as a template. Simply copy it and adapt the following values to match your environment:
- IP addresses (VIP, node IPs in ping resource)
- Node names (psql1, psql2 in location constraints)
- Network interface names (eth0)
- Gateway address for ping monitoring

Then load it with: `sudo crm configure load update pgsql-resource-config.crm`

**Or follow the manual steps below** for this dual-ring configuration:

### Set Cluster Properties

```bash
# Disable STONITH (we're using quorum for split-brain prevention)
sudo crm configure property stonith-enabled=false

# Enable cluster startup
sudo crm configure property no-quorum-policy=ignore

# Resource stickiness. Use rsc_defaults: the cluster property default-resource-stickiness is ignored by
# current Pacemaker (measured with crm_simulate on 3.0.3, the scores do not change). 50 is the value that
# keeps the connectivity failover working with the locations used below, see QUICKSTART.md section 2.11.
sudo crm configure rsc_defaults resource-stickiness=50
```

**Important**: For production, consider implementing proper fencing:
- Network-based fencing (fence_ipmilan, fence_ilo, etc.)
- VM-based fencing (fence_virsh for KVM)
- Even with dual rings, fencing is recommended for split-brain protection

### Create Cluster Resources

```bash
sudo crm configure <<EOF
# PostgreSQL primitive resource
primitive postgres-db ocf:heartbeat:pgtwin \
    params \
        pgdata="/var/lib/pgsql/data" \
        pghost="0.0.0.0" \
        pgport="5432" \
        rep_mode="sync" \
        application_name="postgres_ha" \
        node_list="psql1 psql2" \
        pgpassfile="/var/lib/pgsql/.pgpass" \
        vip="192.168.1.20" \
    op start timeout="300s" interval="0s" \
    op stop timeout="300s" interval="0s" \
    op promote timeout="300s" interval="0s" \
    op demote timeout="300s" interval="0s" \
    op monitor interval="3s" timeout="60s" role="Promoted" \
    op monitor interval="10s" timeout="60s" role="Unpromoted" \
    op notify timeout="90s" interval="0s"

# Virtual IP resource
primitive vip-postgres ocf:heartbeat:IPaddr2 \
    params \
        ip="192.168.1.20" \
        cidr_netmask="24" \
        nic="eth0" \
    op monitor interval="10s" timeout="20s"

# Network path validation - ping external gateway
# This helps cluster detect which node has working external connectivity
primitive ping-gateway ocf:pacemaker:ping \
    params \
        host_list="192.168.1.1" \
        multiplier="100" \
        attempts="3" \
        timeout="2" \
    op monitor interval="10s" timeout="20s"

# Create promotable clone for PostgreSQL
clone postgres-clone postgres-db \
    meta \
        notify="true" \
        clone-max="2" \
        clone-node-max="1" \
        promotable="true" \
        promoted-max="1" \
        promoted-node-max="1"

# Clone ping resource (runs on all nodes)
clone ping-clone ping-gateway \
    meta clone-max="2" clone-node-max="1"

# Resource stickiness - prevent unnecessary failback
# The Promoted role gets the stickiness twice (directly and through the colocated VIP), so it has to stay
# below 75 here (locations 100/50, pingd bonus 200); 50 keeps both failback protection and connectivity failover.
rsc_defaults resource-stickiness=50

# Base location constraints (prefer psql1)
location prefer-psql1 postgres-clone role=Promoted 100: psql1
location prefer-psql2 postgres-clone role=Promoted 50: psql2

# Network connectivity-based location constraint for PROMOTED role
# Prefer node with working external connectivity (higher ping score)
# If Ring 0 (public network) fails on a node, ping score drops to 0
# Cluster will prefer the node with working connectivity for primary
location prefer-connected-promoted postgres-clone role=Promoted \
    rule 200: pingd gt 0

# CRITICAL: Require connectivity for UNPROMOTED (standby) role
# This prevents standby from running on nodes without Ring 0 connectivity
# When standby stops, pgtwin automatically disables sync replication (post-stop notify)
# When standby starts, pgtwin automatically enables sync replication (post-start notify)
location require-connectivity-unpromoted postgres-clone role=Unpromoted \
    rule -inf: pingd eq 0

# Colocation: VIP follows promoted PostgreSQL
colocation vip-with-postgres inf: vip-postgres postgres-clone:Promoted

# Ordering: Start PostgreSQL before VIP
order postgres-before-vip mandatory: postgres-clone:promote vip-postgres:start

commit
EOF
```

**Network Path Validation and Resource Placement Explained**:

The `ping-gateway` resource continuously pings the external gateway (192.168.1.1):
- **Working network**: `pingd` attribute = 100 (successful ping)
- **Broken network**: `pingd` attribute = 0 (failed ping)

**Two distinct location constraints control resource placement:**

**1. Promoted (Primary) Role** - Prefers nodes with connectivity:
```bash
location prefer-connected-promoted postgres-clone role=Promoted \
    rule 200: pingd gt 0
```
- Node with working Ring 0: Base score (100/50) + 200 = 300/250
- Node with broken Ring 0: Base score (100/50) + 0 = 100/50
- **Result**: Primary migrates to node with external connectivity

**2. Unpromoted (Standby) Role** - Requires connectivity:
```bash
location require-connectivity-unpromoted postgres-clone role=Unpromoted \
    rule -inf: pingd eq 0
```
- Node with working Ring 0: Can run standby (score 0)
- Node with broken Ring 0: Cannot run standby (score -inf) → **Resource stopped**
- **Result**: Standby won't start without external connectivity

**Why This Design?**

PostgreSQL replication requires network connectivity between primary and standby. If a standby node loses Ring 0 connectivity but Ring 1 still works (Corosync still connected), the standby cannot replicate because `primary_conninfo` uses Ring 0 addresses.

**Solution**: Stop the standby resource on disconnected nodes. This triggers pgtwin's notify system:
- **`post-stop` notification**: Primary detects standby stopped → disables sync replication → **writes no longer block**
- **`post-start` notification**: Primary detects standby started → enables sync replication → resumes sync mode

**Behavior Matrix**:

| Node State | Can Run Promoted? | Can Run Unpromoted? | Sync Replication? |
|------------|-------------------|---------------------|-------------------|
| Ring 0 + Ring 1 working | Yes (preferred +200) | Yes | Enabled (both nodes) |
| Ring 0 down, Ring 1 up | Yes (score 100/50) | No (-inf) → **Stopped** | Disabled (auto) |
| Both rings down | No (no quorum) | No | N/A (cluster down) |

**Key Parameters**:
- **`notify="true"`**: Enables dynamic sync replication management (v1.6.6 feature)
- **`rep_mode="sync"`**: Synchronous replication mode
- **`vip`**: Used for promoted node discovery
- **`pgpassfile`**: Replication credentials

### Verify Configuration

```bash
# Check cluster configuration
sudo crm configure show

# Verify syntax
sudo crm configure verify

# Check cluster status
sudo crm status
```

---

## Step 9: Start PostgreSQL Cluster

### Wait for Auto-Initialization

The cluster should automatically:
1. Start PostgreSQL on psql1 as primary
2. Auto-initialize psql2 from empty PGDATA (v1.6.6 feature)
3. Start replication
4. Activate VIP on primary

Monitor progress:
```bash
# Watch cluster status
watch -n 2 'sudo crm status'

# Monitor auto-initialization on psql2 (from psql2)
sudo tail -f /var/lib/pgsql/data/.basebackup.log

# Check Pacemaker logs
sudo journalctl -u pacemaker -f
```

**Expected Timeline**:
- **0-30s**: psql1 starts as primary, VIP assigned
- **30-60s**: psql2 auto-initialization begins (pg_basebackup)
- **2-10 min**: pg_basebackup completes (depends on data size)
- **After basebackup**: psql2 starts as standby, replication established

### Verify Cluster Status

```bash
# Check cluster resources
sudo crm status

# Expected output:
# * postgres-clone (Promoted: [ psql1 ], Unpromoted: [ psql2 ])
# * vip-postgres (Started: psql1)
# * ping-clone (Started: [ psql1 psql2 ])
```

### Verify PostgreSQL Replication

On **psql1** (primary):
```bash
# Check replication status
sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

# Expected: One row showing psql2 connected
```

On **psql2** (standby):
```bash
# Check if in recovery mode
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

# Expected: t (true)
```

### Test VIP Assignment

```bash
# Check VIP is assigned to psql1
ip addr show eth0 | grep 192.168.1.20

# Test connection via VIP
psql -h 192.168.1.20 -U postgres -c "SELECT current_timestamp;"
```

---

## Step 10: High Availability Testing

### Test 1: Ring 0 Network Failure with Automatic Failover and Sync Management

**Purpose**: Verify cluster detects broken external connectivity, fails over automatically, and manages synchronous replication correctly

**⚠️ IMPORTANT - Access Requirements**:
- **SSH access to psql1 will be lost** when Ring 0 (eth0) goes down
- You **MUST** have alternative access to psql1 to restore the interface:
  - **Console access** (KVM console, IPMI Serial-over-LAN, physical console)
  - **Pre-schedule restoration** with a delayed command (see alternative below)
- Without alternative access, you'll need to power cycle psql1

**Alternative approach using delayed restoration**:
```bash
# On psql1 - Schedule automatic restoration after 5 minutes
sudo bash -c "nohup sh -c 'sleep 300 && ip link set eth0 up' > /tmp/restore.log 2>&1 &"

# Then immediately disable eth0 for testing
sudo ip link set eth0 down

# eth0 will automatically come back up in 5 minutes
```

**Procedure**:

1. **Check initial state**:
   ```bash
   # On psql1 (current primary)
   sudo crm_mon -A1 | grep pingd
   # Expected: pingd=100 (gateway reachable)

   # Check sync replication enabled
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"
   # Expected: '*' (sync enabled)

   # Check standby connected
   sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
   # Expected: One row (psql2 connected)
   ```

2. **Simulate Ring 0 failure on psql1 (current primary)**:
   ```bash
   # On psql1, disable eth0
   sudo ip link set eth0 down

   # ⚠️ WARNING: SSH connection will drop immediately!
   # You will lose access to psql1 via SSH
   # Continue monitoring from psql2 or use console access to psql1
   ```

3. **Check Corosync status** (requires console access):
   ```bash
   # On psql1 (via console - SSH is down!)
   sudo corosync-cfgtool -s

   # Expected: LINK ID 0 shows disconnected, LINK ID 1 still connected
   ```

   **Note**: If using the delayed restoration method, skip this step and continue monitoring from psql2.

4. **Monitor automatic failover and resource migration**:
   ```bash
   # On psql2
   watch -n 1 'sudo crm status'

   # Expected sequence (timing: ~20-40 seconds total):
   # 1. psql1 ping-gateway fails (pingd=0)
   # 2. psql1 promoted score drops: 100+0=100
   # 3. psql2 promoted score rises: 50+200=250
   # 4. Pacemaker initiates migration:
   #    a. Demote psql1 (promoted → unpromoted)
   #    b. Promote psql2 (unpromoted → promoted)
   # 5. psql1 unpromoted constraint evaluated:
   #    - pingd=0 → rule -inf matches
   #    - Resource STOPPED on psql1
   # 6. VIP migrates to psql2
   ```

5. **Verify failover and sync replication management**:
   ```bash
   # Check cluster status
   sudo crm status

   # Expected:
   # - postgres-clone: Promoted on psql2, psql1 STOPPED (not unpromoted!)
   # - vip-postgres on psql2 (migrated successfully)
   # - ping-clone: psql1 (failed), psql2 (started)
   #
   # Failed Actions (shown at bottom):
   # * vip-postgres start on psql1 returned 'Not installed' ([findif] failed)
   #   This is EXPECTED - eth0 disappeared while VIP was running

   # Check ping attributes
   sudo crm_mon -A1 | grep pingd
   # Expected:
   # - psql1: pingd=0
   # - psql2: pingd=100

   # CRITICAL: Check sync replication automatically disabled
   # On psql2 (new primary)
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"
   # Expected: '' (empty - sync DISABLED automatically via post-stop notify)

   # Check no standbys connected
   sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
   # Expected: 0 rows (psql1 resource stopped, not replicating)

   # Check Pacemaker logs for notify events
   sudo journalctl -u pacemaker -n 50 | grep -i "notify\|sync"
   # Expected: Messages about post-stop notification and disabling sync
   ```

6. **Test writes work without blocking**:
   ```bash
   # On psql2 (current primary in async mode)
   sudo -u postgres psql <<EOF
   CREATE TABLE IF NOT EXISTS ring_failure_test (
       id serial PRIMARY KEY,
       test_time timestamp DEFAULT now(),
       description text
   );
   INSERT INTO ring_failure_test (description) VALUES ('Write during Ring 0 failure on psql1');
   SELECT * FROM ring_failure_test ORDER BY id DESC LIMIT 1;
   EOF

   # Expected: Write completes immediately (no blocking)
   ```

7. **Test external connectivity**:
   ```bash
   # From external machine, VIP should still be reachable
   ping 192.168.1.20

   # Connect to PostgreSQL via VIP
   psql -h 192.168.1.20 -U postgres -c "SELECT current_timestamp;"
   ```

8. **Restore Ring 0 on psql1**:
   ```bash
   # On psql1 (via console access - or wait for automatic restoration if scheduled)
   sudo ip link set eth0 up

   # Wait for interface to come up
   sleep 10

   # CRITICAL: Clean up VIP failure on psql1
   # The VIP resource failed when eth0 disappeared (findif error)
   # Must clean up before resources can migrate back
   sudo crm resource cleanup vip-postgres

   # Wait for ping to recover
   sleep 30

   # Check ping status (SSH should be accessible again now)
   sudo crm_mon -A1 | grep pingd
   # Expected: psql1 pingd=100 (recovered)
   ```

   **Important Notes**:
   - **VIP Failure**: When eth0 goes down, you'll see in `crm status`:
     ```
     Failed Actions:
     * vip-postgres start on psql1 returned 'Not installed' ([findif] failed)
     ```
   - **Why this happens**: The IPaddr2 resource's `findif` script can't find eth0 because it disappeared
   - **Manual Cleanup**: You MUST run `crm resource cleanup vip-postgres` after restoring eth0
   - **Alternative**: Wait 5 minutes for automatic cleanup (failure-timeout) - resources will migrate back automatically
   - **Delayed Restoration**: If using the delayed method, wait 5+ minutes to let automatic cleanup occur

9. **Monitor automatic standby recovery**:
   ```bash
   # On psql2 (primary)
   watch -n 1 'sudo crm status'

   # Expected sequence (timing: ~10-20 seconds):
   # 1. psql1 pingd=100 (recovered)
   # 2. Unpromoted constraint no longer blocks psql1
   # 3. Pacemaker starts unpromoted resource on psql1
   # 4. psql1 connects to psql2 as standby
   # 5. psql2 receives post-start notification
   # 6. Sync replication automatically RE-ENABLED
   ```

10. **Verify full recovery**:
    ```bash
    # Check cluster status
    sudo crm status
    # Expected:
    # - postgres-clone: Promoted on psql2, Unpromoted on psql1
    # - Both nodes online and healthy

    # On psql2 (primary), check sync re-enabled
    sudo -u postgres psql -c "SHOW synchronous_standby_names;"
    # Expected: '*' (sync ENABLED automatically via post-start notify)

    # Check standby connected
    sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
    # Expected: One row (psql1 connected and replicating)

    # Check replication lag
    sudo -u postgres psql -Atc "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;"
    # Expected: Small number (< 1000 bytes lag)
    ```

**Expected Timeline**:
- **t+0 to t+10s**: Ring 0 failure detected, ping score drops
- **t+10 to t+30s**: Primary migration to psql2
- **t+30 to t+35s**: Unpromoted resource stopped on psql1
- **t+35 to t+40s**: Sync replication disabled on psql2
- **Ring 0 restored**
- **t+0 to t+10s**: Ping recovery detected
- **t+10 to t+20s**: Unpromoted starts on psql1
- **t+20 to t+30s**: Replication established, sync re-enabled

**Expected Results**:
✅ Automatic failover when Ring 0 fails on primary
✅ Standby resource STOPPED on disconnected node (not just demoted)
✅ Sync replication automatically DISABLED → writes never block
✅ Services remain accessible via VIP throughout
✅ Automatic recovery when connectivity restored
✅ Sync replication automatically RE-ENABLED when standby reconnects
✅ ~30-40 second downtime during failover
✅ Zero manual intervention required

**What This Tests**:
- **Dual-ring resilience**: Cluster communication continues via Ring 1
- **Network path validation**: Ping resource detects broken external connectivity
- **Intelligent failover**: Cluster fails over to node with working gateway access
- **Connectivity-dependent standby**: Standby won't run without Ring 0
- **Notify integration**: post-stop/post-start automatically manage sync replication
- **Write safety**: No write blocking during network partition
- **Service continuity**: Applications maintain connectivity via VIP
- **Automatic recovery**: Full cluster health restored when network recovers

---

### Test 1b: Ring 0 Failure on Standby Node

**Purpose**: Verify standby stops when it loses connectivity (no failover needed)

**⚠️ IMPORTANT - Access Requirements**:
- **SSH access to psql1 will be lost** when Ring 0 (eth0) goes down
- Use console access or the delayed restoration method (see Test 1)

**Procedure**:

1. **Initial state**: psql1 promoted, psql2 unpromoted (after Test 1)
   ```bash
   sudo crm status
   # Expected: Promoted on psql2, Unpromoted on psql1

   # Check sync enabled
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"
   # Expected: '*'
   ```

2. **Simulate Ring 0 failure on psql1 (standby)**:
   ```bash
   # On psql1 (standby)
   # Optional: Schedule automatic restoration
   sudo bash -c "nohup sh -c 'sleep 300 && ip link set eth0 up' > /tmp/restore.log 2>&1 &"

   # Disable eth0
   sudo ip link set eth0 down

   # ⚠️ WARNING: SSH connection will drop immediately!
   ```

3. **Monitor standby resource stop**:
   ```bash
   # On psql2 (primary)
   watch -n 1 'sudo crm status'

   # Expected sequence (timing: ~10-20 seconds):
   # 1. psql1 ping-gateway fails (pingd=0)
   # 2. Unpromoted constraint blocks psql1 (score -inf)
   # 3. Pacemaker STOPS unpromoted resource on psql1
   # 4. psql2 receives post-stop notification
   # 5. Sync replication DISABLED on psql2
   ```

4. **Verify sync disabled and writes work**:
   ```bash
   # On psql2 (primary)
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"
   # Expected: '' (disabled)

   # Test write (should not block)
   sudo -u postgres psql -c "INSERT INTO ring_failure_test (description) VALUES ('Standby lost Ring 0');"
   # Expected: Immediate completion
   ```

5. **Restore Ring 0 on psql1**:
   ```bash
   # On psql1 (via console - or wait for automatic restoration)
   sudo ip link set eth0 up
   sleep 30

   # Note: VIP cleanup NOT needed here - VIP is running on psql2 (primary)
   # The "[findif] failed" error only occurs on the node where VIP was running when eth0 went down
   ```

6. **Verify automatic recovery**:
   ```bash
   # On psql2
   sudo crm status
   # Expected: Unpromoted started on psql1

   # Check sync re-enabled
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"
   # Expected: '*'

   # Check replication
   sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"
   # Expected: One row (psql1 replicating)
   ```

**Expected Results**:
✅ Standby stops when it loses Ring 0 (no failover - primary unaffected)
✅ Sync replication automatically disabled
✅ Writes on primary never block
✅ Automatic recovery when connectivity restored
✅ No manual intervention needed

---

### Test 2: Ring 1 Network Failure (Direct Link)

**Purpose**: Verify cluster continues operating when direct link fails

**Note**: SSH access remains available during this test (SSH uses Ring 0/eth0).

**Procedure**:

1. **Simulate Ring 1 failure on psql1**:
   ```bash
   # On psql1, disable eth1 (Ring 1 - direct link only)
   sudo ip link set eth1 down

   # SSH remains accessible - only Corosync ring 1 is affected
   ```

2. **Check Corosync status**:
   ```bash
   sudo corosync-cfgtool -s

   # Expected: LINK ID 1 shows disconnected, LINK ID 0 still connected
   ```

3. **Verify cluster still has quorum**:
   ```bash
   sudo crm status

   # Expected: Both nodes still online
   ```

4. **Restore Ring 1**:
   ```bash
   sudo ip link set eth1 up
   sleep 10
   sudo corosync-cfgtool -s
   ```

**Expected Result**: ✅ Cluster remains operational using Ring 0

---

### Test 3: Complete Network Isolation (Split-Brain Scenario)

**Purpose**: Verify split-brain protection with dual rings

**⚠️ CRITICAL - Access Requirements**:
- **ALL network access to psql1 will be lost** (both SSH and cluster communication)
- **MUST use console access** (KVM, IPMI, physical) - delayed restoration won't help here
- **Alternative**: Use scheduled restoration with a longer delay (10 minutes)

**Procedure**:

1. **Simulate complete network partition**:
   ```bash
   # On psql1 - Optional: schedule restoration
   sudo bash -c "nohup sh -c 'sleep 600 && ip link set eth0 up && ip link set eth1 up' > /tmp/restore.log 2>&1 &"

   # Disable both interfaces
   sudo ip link set eth0 down
   sudo ip link set eth1 down

   # ⚠️ CRITICAL: ALL network access lost immediately!
   # Switch to console access or wait for automatic restoration
   ```

2. **Check cluster status on psql1** (requires console access):
   ```bash
   # On psql1 (via console only)
   sudo crm status

   # Expected: psql1 loses quorum, stops resources
   ```

3. **Check cluster status on psql2**:
   ```bash
   # On psql2
   sudo crm status

   # Expected: psql2 detects psql1 offline, may fence or wait
   ```

4. **Check quorum**:
   ```bash
   # On psql2
   sudo corosync-quorumtool

   # With two_node=1, psql2 should maintain quorum alone
   ```

5. **Restore network on psql1**:
   ```bash
   # On psql1 (via console - or wait for scheduled restoration)
   sudo ip link set eth0 up
   sudo ip link set eth1 up

   # Wait for cluster to re-synchronize
   sleep 30

   # Check for any failed resources
   sudo crm status

   # If VIP shows failed on psql1, clean it up
   # (Usually not needed - Pacemaker stops resources before interfaces disappear)
   # sudo crm resource cleanup vip-postgres

   # SSH access should be restored now
   ```

**Expected Result**: ✅ No split-brain, proper quorum handling

**Note**: VIP failures ("`vip-postgres start on psql1 returned 'Not installed' ([findif] failed)`") are rare in this test since Pacemaker stops resources when quorum is lost, before interfaces disappear. VIP cleanup is usually only needed in Test 1 where the interface disappears while the node still has quorum.

---

### Test 4: Primary Node Failure (Automatic Failover)

**Purpose**: Verify automatic failover to standby

**Procedure**:

1. **Stop Pacemaker on current primary (psql1)**:
   ```bash
   # On psql1
   sudo systemctl stop pacemaker
   ```

2. **Monitor failover on psql2**:
   ```bash
   # On psql2
   watch -n 1 'sudo crm status'

   # Expected: psql2 promotes to primary, VIP moves to psql2
   ```

3. **Verify VIP migration**:
   ```bash
   # From external machine
   ping 192.168.1.20

   # Should remain reachable
   ```

4. **Check PostgreSQL on psql2**:
   ```bash
   # On psql2
   sudo -u postgres psql -c "SELECT pg_is_in_recovery();"

   # Expected: f (false - now primary)
   ```

5. **Restore psql1**:
   ```bash
   # On psql1
   sudo systemctl start pacemaker

   # Wait for recovery
   sleep 30
   sudo crm status

   # Expected: psql1 joins as standby
   ```

**Expected Timeline**:
- **0-10s**: Pacemaker detects psql1 failure
- **10-30s**: psql2 promoted to primary
- **30-45s**: VIP migrates to psql2
- **Total**: ~30-60 seconds downtime

**Expected Result**: ✅ Automatic failover completes successfully

---

### Test 5: Planned Failover

**Purpose**: Test manual failover for maintenance

**Procedure**:

1. **Current state** (psql2 is primary from Test 4):
   ```bash
   sudo crm status
   ```

2. **Perform planned migration**:
   ```bash
   # Move primary back to psql1
   sudo crm resource move postgres-clone psql1

   # Wait for migration
   sleep 30

   # CRITICAL: Clear location constraint
   sudo crm resource clear postgres-clone
   ```

3. **Verify migration**:
   ```bash
   sudo crm status

   # Expected: postgres-clone promoted on psql1
   #           VIP on psql1
   #           psql2 as standby
   ```

4. **Check replication re-established**:
   ```bash
   # On psql1
   sudo -u postgres psql -x -c "SELECT * FROM pg_stat_replication;"

   # Expected: psql2 connected as standby
   ```

**Expected Timeline**: 15-30 seconds for graceful migration

**Expected Result**: ✅ Clean migration with no data loss

---

### Test 6: Notify Support (Dynamic Sync Replication)

**Purpose**: Verify synchronous replication automatically adjusts when standby fails

**Procedure**:

1. **Check initial sync replication state**:
   ```bash
   # On current primary (psql1)
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"

   # Expected: * (sync enabled with standby connected)
   ```

2. **Put standby in maintenance**:
   ```bash
   sudo crm node standby psql2
   ```

3. **Check sync replication auto-disabled**:
   ```bash
   # On psql1 (still primary)
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"

   # Expected: '' (empty - sync disabled automatically)

   # Check logs
   sudo journalctl -u pacemaker | grep -i "disabling synchronous"
   ```

4. **Verify writes still work**:
   ```bash
   # On psql1
   sudo -u postgres psql <<EOF
   CREATE TABLE test_notify (id serial, data text);
   INSERT INTO test_notify (data) VALUES ('test during async mode');
   SELECT * FROM test_notify;
   EOF

   # Expected: No blocking, writes complete immediately
   ```

5. **Bring standby back online**:
   ```bash
   sudo crm node online psql2

   # Wait for startup
   sleep 30
   ```

6. **Check sync replication re-enabled**:
   ```bash
   # On psql1
   sudo -u postgres psql -c "SHOW synchronous_standby_names;"

   # Expected: * (sync re-enabled)

   # Check logs
   sudo journalctl -u pacemaker | grep -i "enabling synchronous"
   ```

**Expected Result**: ✅ Automatic sync/async switching prevents write blocking

---

## Test 7: Dual Ring Redundancy Validation

**Purpose**: Verify both rings actively participate in cluster communication

**Procedure**:

1. **Monitor Corosync traffic on both interfaces**:
   ```bash
   # On psql1, monitor Ring 0 traffic
   sudo tcpdump -i eth0 -n 'port 5405' &
   TCPDUMP_PID_RING0=$!

   # Monitor Ring 1 traffic
   sudo tcpdump -i eth1 -n 'port 5407' &
   TCPDUMP_PID_RING1=$!

   # Wait 10 seconds
   sleep 10

   # Stop capture
   sudo kill $TCPDUMP_PID_RING0 $TCPDUMP_PID_RING1
   ```

2. **Check Corosync statistics**:
   ```bash
   sudo corosync-cfgtool -s
   ```

3. **Verify ring status in detail**:
   ```bash
   sudo corosync-cmapctl | grep -i ring
   ```

**Expected Output**:
```
runtime.totem.pg.mrp.srp.members.1.ip (str) = r(0) ip(192.168.1.10) r(1) ip(10.10.10.1)
runtime.totem.pg.mrp.srp.members.2.ip (str) = r(0) ip(192.168.1.11) r(1) ip(10.10.10.2)
```

**Expected Result**: ✅ Both rings show active traffic and no faults

---

## Monitoring and Troubleshooting

### Monitor Cluster Status

```bash
# Real-time cluster monitoring with attributes
sudo crm_mon -Arf1

# Corosync ring status
sudo corosync-cfgtool -s

# Quorum status
sudo corosync-quorumtool -s

# Check ping connectivity scores
sudo crm_mon -A1 | grep pingd

# View ping resource details
sudo crm resource status ping-gateway

# PostgreSQL replication lag
sudo -u postgres psql -x -c "
SELECT
  application_name,
  client_addr,
  state,
  sync_state,
  pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) AS lag_bytes
FROM pg_stat_replication;
"
```

### Common Issues and Solutions

#### Issue: Only one ring active

**Symptoms**:
```bash
sudo corosync-cfgtool -s
# Shows only Ring 0 active
```

**Diagnosis**:
```bash
# Check eth1 is up
ip addr show eth1

# Check connectivity
ping -c 3 10.10.10.2  # from psql1

# Check firewall
sudo firewall-cmd --list-all
```

**Solution**:
```bash
# Ensure eth1 is up
sudo ip link set eth1 up

# Verify direct link connectivity
# If using firewalld, ensure eth1 in trusted zone
sudo firewall-cmd --permanent --zone=trusted --add-interface=eth1
sudo firewall-cmd --reload

# Restart Corosync
sudo systemctl restart corosync
```

---

#### Issue: Split-brain after network partition

**Symptoms**:
- Both nodes think they are primary
- Duplicate VIP assignments

**Diagnosis**:
```bash
# Check if both nodes have VIP
ip addr show | grep 192.168.1.20

# Check PostgreSQL role on both nodes
sudo -u postgres psql -c "SELECT pg_is_in_recovery();"
```

**Solution**:
```bash
# Emergency: Stop cluster on one node (choose standby if possible)
sudo crm node standby psql2

# Verify cluster state on psql1
sudo crm status

# Cleanup resources if needed
sudo crm resource cleanup postgres-clone
sudo crm resource cleanup vip-postgres

# Bring psql2 back online
sudo crm node online psql2
```

**Prevention**: Enable proper fencing (STONITH) even with dual rings

---

#### Issue: High replication lag during single-ring operation

**Symptoms**:
```bash
# Large lag_bytes value
sudo -u postgres psql -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(), replay_lsn) FROM pg_stat_replication;"
```

**Diagnosis**:
```bash
# Check which ring is down
sudo corosync-cfgtool -s

# Check network throughput on active ring
# Install iperf3 if needed
iperf3 -s  # on psql2
iperf3 -c psql2  # on psql1
```

**Solution**:
- Restore failed ring to improve throughput
- If Ring 0 (switch) is slower, ensure direct Ring 1 is active
- Consider upgrading network hardware if sustained lag occurs

---

#### Issue: Auto-initialization fails on psql2

**Symptoms**:
```bash
# On psql2
sudo crm status
# Shows: postgres-clone failed to start
```

**Diagnosis**:
```bash
# Check auto-init logs
sudo tail -100 /var/lib/pgsql/data/.basebackup.log

# Check Pacemaker logs
sudo journalctl -u pacemaker -n 100

# Verify .pgpass file
ls -l /var/lib/pgsql/.pgpass
sudo -u postgres cat /var/lib/pgsql/.pgpass
```

**Solution**:
```bash
# Fix .pgpass permissions if wrong
sudo chmod 600 /var/lib/pgsql/.pgpass
sudo chown postgres:postgres /var/lib/pgsql/.pgpass

# Clear failed PGDATA and retry
sudo crm node standby psql2
sudo rm -rf /var/lib/pgsql/data/*
sudo mkdir -p /var/lib/pgsql/data
sudo chown postgres:postgres /var/lib/pgsql/data
sudo chmod 700 /var/lib/pgsql/data
sudo crm node online psql2

# Monitor auto-init
sudo tail -f /var/lib/pgsql/data/.basebackup.log
```

---

### Notify System Timing and Behavior

**Understanding pgtwin v1.6.6 Notify Integration**:

The connectivity-dependent standby design relies on pgtwin's notify handlers to automatically manage synchronous replication. Understanding the timing and sequencing is critical for troubleshooting.

#### Notify Events and Handlers

**pgtwin implements these notify handlers** (pgtwin:2394-2430):

| Notify Event | Trigger | Handler Action | Timing |
|--------------|---------|----------------|--------|
| `post-start` | Unpromoted resource starts | Enable sync if promoted exists | After standby starts |
| `post-stop` | Unpromoted resource stops | Disable sync if no standbys | After standby stops |
| `post-promote` | Resource promoted | Update replication config | After promotion |
| `pre-demote` | Before resource demoted | Prepare for standby role | Before demotion |

#### Sequence: Ring 0 Fails on Primary

**Detailed Event Timeline**:

```
t+0s    Ring 0 fails on psql1 (eth0 down)
        └─> Corosync Ring 0 fault detected
        └─> Corosync Ring 1 still active (cluster OK)

t+10s   Ping monitor detects failure
        └─> ping-gateway on psql1: pingd = 0
        └─> ping-gateway on psql2: pingd = 100

t+11s   Pacemaker recalculates scores
        └─> psql1 promoted score: 100 + 0 = 100
        └─> psql2 promoted score: 50 + 200 = 250
        └─> Decision: Migrate promoted to psql2

t+12s   Pacemaker initiates migration
        └─> Action 1: Demote postgres-clone on psql1
        │   └─> pgsql_demote() called
        │   └─> PostgreSQL stopped on psql1
        │   └─> standby.signal created
        │   └─> primary_conninfo updated
        │   └─> PostgreSQL started as standby on psql1
        │
        └─> Action 2: Promote postgres-clone on psql2
            └─> pgsql_promote() called
            └─> pg_ctl promote executed
            └─> Replication slot created
            └─> psql2 now PRIMARY

t+30s   Demote completes, psql1 in unpromoted role
        └─> Pacemaker evaluates unpromoted constraints
        └─> Rule: pingd eq 0 → score -inf on psql1
        └─> Decision: Stop unpromoted on psql1

t+31s   Pacemaker stops postgres-clone on psql1
        └─> pgsql_stop() called
        └─> PostgreSQL stopped on psql1

t+32s   Pacemaker sends post-stop notification
        └─> All promoted resources receive notification
        └─> psql2 (promoted) receives: post-stop

t+33s   pgtwin on psql2 handles post-stop
        └─> pgsql_notify() called with type=post-stop
        └─> Check: Is this node promoted? YES
        └─> Query: SELECT count(*) FROM pg_stat_replication
        └─> Result: 0 (no standbys connected)
        └─> Check: rep_mode=sync? YES
        └─> Action: disable_sync_replication()
        │   └─> ALTER SYSTEM SET synchronous_standby_names = ''
        │   └─> SELECT pg_reload_conf()
        └─> Log: "Synchronous replication disabled"

t+34s   Sync replication disabled
        └─> SHOW synchronous_standby_names → ''
        └─> Writes no longer block
        └─> Cluster in async mode

--- Ring 0 restored on psql1 ---

t+0s    Ring 0 restored (eth0 up)
        └─> Ping monitor detects recovery

t+10s   ping-gateway on psql1: pingd = 100
        └─> Pacemaker recalculates unpromoted constraints
        └─> psql1 no longer blocked (pingd > 0)

t+11s   Pacemaker starts unpromoted on psql1
        └─> pgsql_start() called
        └─> PostgreSQL starts as standby
        └─> Connects to psql2 via primary_conninfo

t+15s   Replication connection established
        └─> psql2 sees connection in pg_stat_replication

t+16s   Pacemaker sends post-start notification
        └─> All promoted resources receive notification
        └─> psql2 (promoted) receives: post-start

t+17s   pgtwin on psql2 handles post-start
        └─> pgsql_notify() called with type=post-start
        └─> Check: Is this node promoted? YES
        └─> Check: rep_mode=sync? YES
        └─> Check: Are there unpromoted resources?
        │   └─> OCF_RESKEY_CRM_meta_notify_unpromoted_resource
        │   └─> Result: YES (psql1 unpromoted active)
        └─> Action: enable_sync_replication()
        │   └─> ALTER SYSTEM SET synchronous_standby_names = '*'
        │   └─> SELECT pg_reload_conf()
        └─> Log: "Synchronous replication enabled"

t+18s   Sync replication enabled
        └─> SHOW synchronous_standby_names → '*'
        └─> Standby appears in pg_stat_replication
        └─> sync_state: 'sync'
        └─> Cluster back to sync mode
```

#### Key Timing Parameters

**Pacemaker Intervals**:
- `cluster-recheck-interval`: 1min (how often Pacemaker recalculates constraints)
- `ping monitor interval`: 10s (how often ping checks gateway)
- `postgres monitor interval`: 3s (promoted), 10s (unpromoted)

**Critical Timings**:
- **Ping detection**: 10-20s (depends on attempts and timeout)
- **Migration decision**: 1-5s (Pacemaker policy engine)
- **Demote/Promote**: 10-30s (depends on PostgreSQL responsiveness)
- **Notify delivery**: < 1s (Pacemaker internal)
- **Sync toggle**: < 1s (ALTER SYSTEM + pg_reload_conf)

**Total Downtime** (Ring 0 failure on primary):
- **Best case**: ~30 seconds
- **Typical**: ~40 seconds
- **Worst case**: ~60 seconds

#### Behavior Matrix: All Scenarios

| Scenario | Primary Role | Standby Role | Sync Replication | Notify Events | Result |
|----------|--------------|--------------|------------------|---------------|--------|
| **Normal operation** | psql1 promoted | psql2 unpromoted | Enabled ('*') | - | Full sync replication |
| **Ring 0 fails on primary** | Migrates to psql2 | Stops on psql1 | Disabled ('') | post-stop | Async mode, writes OK |
| **Ring 0 fails on standby** | Stays on psql1 | Stops on psql2 | Disabled ('') | post-stop | Async mode, writes OK |
| **Ring 0 restored on stopped** | Stays on psql2 | Starts on psql1 | Enabled ('*') | post-start | Back to sync mode |
| **Ring 1 fails (Ring 0 OK)** | No change | No change | Enabled ('*') | - | Corosync on Ring 0 |
| **Both rings fail (nodes alive)** | Cluster down | Cluster down | N/A | - | Network isolation, quorum lost |
| **Manual standby stop** | No change | Stopped | Disabled ('') | post-stop | Async mode |
| **Manual standby start** | No change | Started | Enabled ('*') | post-start | Sync mode restored |

#### Troubleshooting Notify Issues

**Symptom**: Sync replication not automatically disabled after standby stops

**Diagnosis**:
```bash
# Check if notify is enabled
sudo crm configure show postgres-clone | grep notify
# Expected: notify="true"

# Check Pacemaker logs for notify events
sudo journalctl -u pacemaker -n 100 | grep -i notify

# Check if pgtwin received notification
sudo journalctl -u pacemaker | grep "post-stop\|post-start"

# Manually check standby count
sudo -u postgres psql -Atc "SELECT count(*) FROM pg_stat_replication;"
```

**Solution**:
```bash
# If notify not enabled, fix configuration
sudo crm configure edit postgres-clone
# Add: meta notify="true"

# If notify enabled but not working, check OCF metadata
sudo /usr/lib/ocf/resource.d/heartbeat/pgtwin meta-data | grep notify

# Manual sync toggle if needed (temporary fix)
sudo -u postgres psql -c "ALTER SYSTEM SET synchronous_standby_names = '';"
sudo -u postgres psql -c "SELECT pg_reload_conf();"
```

---

## Performance Considerations

### Ring Latency

**Measure latency on each ring**:
```bash
# Ring 0 (public network)
ping -c 100 192.168.1.11 | tail -1

# Ring 1 (direct link)
ping -c 100 10.10.10.2 | tail -1
```

**Expected**:
- Ring 0: < 1ms (on same switch)
- Ring 1: < 0.5ms (direct cable, should be faster)

**Impact**: Lower latency improves:
- Faster heartbeat detection
- Quicker failover
- Lower replication lag

---

### Network Throughput

**Test throughput on each ring** (requires iperf3):

```bash
# On psql2 (server)
iperf3 -s

# On psql1 (client)
# Test Ring 0 (via switch)
iperf3 -c 192.168.1.11

# Test Ring 1 (direct link)
iperf3 -c 10.10.10.2
```

**Expected**:
- Gigabit NICs: 900+ Mbps
- 10 Gigabit NICs: 9000+ Mbps
- Direct link should match or exceed switch-based ring

**Impact on PostgreSQL**:
- Higher throughput = faster pg_basebackup
- Lower replication lag under heavy write load
- Better performance during recovery

---

## Advantages of Dual Ring Setup

### vs. Single Network

| Aspect | Single Network | Dual Ring |
|--------|---------------|-----------|
| **Network Redundancy** | ❌ Single point of failure | ✅ Survives network path failure |
| **Split-Brain Protection** | ⚠️ Requires STONITH | ✅ Enhanced with dual paths |
| **Heartbeat Reliability** | ⚠️ Switch failure = cluster down | ✅ Continues on surviving ring |
| **Maintenance** | ❌ Network maintenance = downtime | ✅ Can maintain one path at a time |

### vs. SBD (Storage-Based Death)

| Aspect | SBD | Dual Ring |
|--------|-----|-----------|
| **Shared Storage Required** | ✅ Yes (iSCSI/FC/shared disk) | ❌ No |
| **Infrastructure Cost** | Higher (storage network) | Lower (just cables) |
| **Complexity** | Medium (storage setup) | Low (network config) |
| **Failure Detection** | Fast (SBD watchdog) | Fast (Corosync heartbeat) |
| **Fencing Mechanism** | Strong (hardware reset) | Software-based (quorum) |

**Recommendation**:
- **Development/Testing**: Dual ring (no SBD) is sufficient
- **Production**: Combine dual ring + proper fencing (IPMI, iLO, etc.)

---

## Production Best Practices

### 1. Enable Proper Fencing

Even with dual rings, implement hardware fencing:

```bash
# Example: IPMI-based fencing
sudo crm configure <<EOF
primitive stonith-psql1 stonith:fence_ipmilan \
    params \
        pcmk_host_list="psql1" \
        ipaddr="192.168.1.100" \
        login="admin" \
        passwd="ipmi_password" \
        lanplus="true" \
    op monitor interval="60s"

primitive stonith-psql2 stonith:fence_ipmilan \
    params \
        pcmk_host_list="psql2" \
        ipaddr="192.168.1.101" \
        login="admin" \
        passwd="ipmi_password" \
        lanplus="true" \
    op monitor interval="60s"

location stonith-psql1-location stonith-psql1 -inf: psql1
location stonith-psql2-location stonith-psql2 -inf: psql2

property stonith-enabled=true
commit
EOF
```

### 2. Monitor Ring Health

Set up monitoring:
```bash
# Create monitoring script
sudo tee /usr/local/bin/monitor-corosync-rings.sh <<'EOF'
#!/bin/bash
STATUS=$(corosync-cfgtool -s 2>&1)
if echo "$STATUS" | grep -q "FAULTY"; then
    echo "ALERT: Corosync ring fault detected"
    echo "$STATUS" | mail -s "Corosync Ring Failure" admin@example.com
fi
EOF

sudo chmod +x /usr/local/bin/monitor-corosync-rings.sh

# Add to cron (every 5 minutes)
echo "*/5 * * * * /usr/local/bin/monitor-corosync-rings.sh" | sudo crontab -
```

### 3. Use Bonding for Ring 0

For even better Ring 0 redundancy, use network bonding:

```bash
# /etc/sysconfig/network/ifcfg-bond0
BOOTPROTO='static'
IPADDR='192.168.1.10'
NETMASK='255.255.255.0'
BONDING_MODULE_OPTS='mode=active-backup miimon=100'
BONDING_SLAVE_0='eth0'
BONDING_SLAVE_1='eth2'
STARTMODE='auto'
```

### 4. Dedicated Direct Link

For Ring 1:
- Use **crossover cable** or **direct connection** (not through switch)
- Higher speed if possible (10G preferred for large databases)
- Physically separate from Ring 0 (different cable paths)

### 5. Regular Testing

Schedule regular HA tests:
- Monthly: Test single ring failure
- Quarterly: Test complete failover
- Annually: Test split-brain scenarios

---

## Conclusion

This dual-ring Corosync setup provides:

✅ **Network redundancy** without shared storage
✅ **Simplified infrastructure** (no SBD device needed)
✅ **Production-grade HA** when combined with proper fencing
✅ **Cost-effective** solution for 2-node clusters
✅ **Zero-touch standby deployment** (pgtwin v1.6.6 auto-init)
✅ **Dynamic sync replication** (pgtwin v1.6.6 notify support)

### Next Steps

1. Test all failure scenarios in this guide
2. Implement proper fencing for production
3. Set up monitoring and alerting
4. Document your specific network topology
5. Create runbooks for common operations

### Further Reading

- [Corosync Documentation](https://corosync.github.io/corosync/)
- [Pacemaker Explained](https://clusterlabs.org/pacemaker/doc/)
- [PostgreSQL Replication](https://www.postgresql.org/docs/current/high-availability.html)
- [pgtwin Documentation](README.md)

---

**Questions or feedback?** Open an issue on the pgtwin GitHub repository!
