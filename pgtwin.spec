#
# spec file for package pgtwin
#
# Copyright (c) 2025 SUSE LLC
#
# All modifications and additions to the file contributed by third parties
# remain the property of their copyright owners, unless otherwise agreed
# upon. The license for this file, and modifications and additions to the
# file, is the same license as for the pristine package itself (unless the
# license for the pristine package is not an Open Source License, in which
# case the license is the MIT License). An "Open Source License" is a
# license that conforms to the Open Source Definition (Version 1.9)
# published by the Open Source Initiative.

Name:           pgtwin
Version:        1.7.12
Release:        1
Summary:        PostgreSQL 2-Node High Availability OCF Resource Agent
License:        GPL-2.0-or-later
Group:          Productivity/Clustering/HA
URL:            https://github.com/yourusername/pgtwin
Source0:        %{name}-%{version}.tar.gz
BuildArch:      noarch

# Runtime dependencies
Requires:       pacemaker >= 3.0
Requires:       postgresql-server >= 17
Requires:       resource-agents
Requires:       bash
Requires:       gawk
Requires:       grep
Requires:       util-linux

# Build dependencies (minimal for noarch shell script)
BuildRequires:  bash

%description
pgtwin (PostgreSQL Twin) is a production-ready OCF resource agent for
managing PostgreSQL 17+ in a 2-node High Availability cluster using
Pacemaker and Corosync.

Features:
- Physical streaming replication with zero data loss
- Automatic failover with 30-60 second recovery time
- Virtual IP (VIP) management for transparent client reconnection
- Automatic configuration validation (prevents split-brain scenarios)
- pg_rewind support for fast timeline synchronization
- Asynchronous pg_basebackup for full cluster resync
- Automatic replication recovery (v1.6)
- Dynamic promoted node discovery

This package is designed specifically for 2-node clusters and provides
enterprise-grade HA without the complexity of 3+ node setups.

%prep
%setup -q

%build
# Nothing to build for shell script

%install
# Create OCF directory structure
install -d -m 0755 %{buildroot}%{_prefix}/lib/ocf/resource.d/heartbeat

# Install the OCF resource agent
install -m 0755 pgtwin %{buildroot}%{_prefix}/lib/ocf/resource.d/heartbeat/pgtwin

# Install documentation
install -d -m 0755 %{buildroot}%{_docdir}/%{name}
install -m 0644 README.md %{buildroot}%{_docdir}/%{name}/
install -m 0644 CHANGELOG.md %{buildroot}%{_docdir}/%{name}/
install -m 0644 QUICKSTART.md %{buildroot}%{_docdir}/%{name}/
install -m 0644 CHEATSHEET.md %{buildroot}%{_docdir}/%{name}/
install -m 0644 PROJECT_SUMMARY.md %{buildroot}%{_docdir}/%{name}/
install -m 0644 LICENSE %{buildroot}%{_docdir}/%{name}/
install -m 0644 VERSION %{buildroot}%{_docdir}/%{name}/

%files
%defattr(-,root,root,-)
%{_prefix}/lib/ocf/resource.d/heartbeat/pgtwin
%dir %{_docdir}/%{name}
%doc %{_docdir}/%{name}/README.md
%doc %{_docdir}/%{name}/CHANGELOG.md
%doc %{_docdir}/%{name}/QUICKSTART.md
%doc %{_docdir}/%{name}/CHEATSHEET.md
%doc %{_docdir}/%{name}/PROJECT_SUMMARY.md
%doc %{_docdir}/%{name}/VERSION
%license %{_docdir}/%{name}/LICENSE

%changelog
* Mon Nov 03 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.6.0-1
- Release v1.6.0: Automatic Replication Recovery
- Add automatic replication health monitoring on standby nodes
- Add incremental failure counter with configurable threshold
- Add auto-triggered pg_rewind/pg_basebackup on replication failures
- Add dynamic promoted node discovery (VIP, node scan, CIB parsing)
- Add new parameters: vip, replication_failure_threshold
- Known issues: failure counter may not increment correctly, missing passfile in primary_conninfo

* Sat Nov 02 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.5.0-1
- Release v1.5.0: Enhanced Configuration Validation
- Add 6 new PostgreSQL configuration checks on startup
- Add CRITICAL check for restart_after_crash (prevents split-brain)
- Add WARNING checks for wal_sender_timeout, max_standby_streaming_delay
- Add archive_command error handling validation
- Add runtime archive failure monitoring on primary
- Add comprehensive README.postgres.md configuration guide

* Fri Nov 01 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.4.0-1
- Release v1.4.0: Critical Bug Fixes
- Fix promotion failure with standby.signal removal
- Add dual location constraints for proper failover migration
- Add automatic application_name management
- Add STONITH/SBD configuration for fencing

* Thu Oct 31 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.3.0-1
- Release v1.3.0: Configuration Validation Framework
- Add 8 comprehensive checks on PostgreSQL start
- Validate PostgreSQL version, replication settings, archive mode
- Validate replication user, slots, VIP, sync mode
- Early blocking for critical misconfigurations

* Wed Oct 30 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.2.0-1
- Release v1.2.0: Disk Space Calculation Refactoring
- Switch from logical database size to actual filesystem usage
- Use du -sb for accurate total space requirements
- Improve disk space safety margin calculations

* Tue Oct 29 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.1.0-1
- Release v1.1.0: Feature Enhancements
- Add application name validation and sanitization
- Add disk space pre-check before pg_basebackup
- Add backup mode semantics (backup vs no-backup)
- Add asynchronous pg_basebackup support
- Add enhanced .pgpass credential support

* Mon Oct 28 2025 Berthold Gunreben <azouhr@opensuse.org> - 1.0.0-1
- Initial release of pgtwin
- PostgreSQL 17 High Availability support
- Physical streaming replication with replication slots
- Automatic failover with Pacemaker
- Virtual IP management
- pg_rewind support for timeline reconciliation
- Synchronous and asynchronous replication modes
