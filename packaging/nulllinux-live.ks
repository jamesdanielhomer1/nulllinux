# Build-time recipe for the nullLinux Try / Install live medium.
# Disk directives below apply only to livemedia-creator's disposable image.
# Installation from the running desktop uses Fedora's interactive liveinst.
lang en_GB.UTF-8
keyboard --vckeymap=gb --xlayouts='gb'
timezone Europe/London --utc
selinux --enforcing
firewall --enabled --service=mdns
xconfig --startxonboot
zerombr
clearpart --all
part / --size=12288 --fstype ext4
services --enabled=NetworkManager --disabled=network,sshd
shutdown
rootpw --lock
network --bootproto=dhcp --device=link --activate --hostname=nulllinux

url --url=https://download.fedoraproject.org/pub/fedora/linux/releases/$releasever/Everything/$basearch/os/
repo --name=fedora --mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=fedora-$releasever&arch=$basearch
repo --name=updates --mirrorlist=https://mirrors.fedoraproject.org/metalink?repo=updates-released-f$releasever&arch=$basearch
# bin/null-iso substitutes the local repository path.
repo --name=nulllinux --baseurl=file://NULLLINUX_REPO

%packages
@core
@standard
@hardware-support
kernel
dracut-live
dracut-config-generic
memtest86+
syslinux
anaconda
anaconda-install-env-deps
anaconda-live
anaconda-webui
@anaconda-tools
firefox
polkit
nulllinux
-@dial-up
-@input-methods
-gfs2-utils
-reiserfs-utils
%end

%post --erroronfail --interpreter=/usr/bin/bash
set -euo pipefail
test -x /usr/bin/liveinst
test -d /usr/share/cockpit/anaconda-webui
test -x /opt/nulllinux/bin/null-live
test -f /opt/nulllinux/lib/live.sh
echo nulllinux > /etc/hostname
mkdir -p /usr/libexec /usr/share/anaconda/post-scripts /usr/share/applications
mkdir -p /etc/systemd/system/getty@tty1.service.d /etc/systemd/system/sddm.service.d

# Anaconda detects ID and VARIANT_ID, not ID_LIKE. Keep Fedora's Btrfs and
# EFI defaults for our branded ID. Its base profile leaves account creation
# visible; Workstation/KDE defer it to first-boot tools we do not ship.
mkdir -p /etc/anaconda/profile.d
cat > /etc/anaconda/profile.d/nulllinux.conf <<'ANACONDA_PROFILE'
[Profile]
profile_id = nulllinux
base_profile = fedora

[Profile Detection]
os_id = nulllinux

[User Interface]
webui_web_engine = firefox
ANACONDA_PROFILE
chmod 0644 /etc/anaconda/profile.d/nulllinux.conf

# The marker and temporary account are created at live boot, not in the base
# image. All privilege checks require the live kernel argument and marker.
cat > /usr/libexec/nulllinux-live-check <<'CHECK'
#!/usr/bin/env bash
. /opt/nulllinux/lib/live.sh
null_is_live
CHECK

cat > /usr/libexec/nulllinux-live-setup <<'SETUP'
#!/usr/bin/env bash
set -euo pipefail
case " $(cat /proc/cmdline) " in *" rd.live.image "*) ;; *) exit 0 ;; esac
if ! getent passwd live >/dev/null; then
  useradd -m -c "nullLinux Live Session" -s /bin/bash live
fi
passwd -d live
install -m 0644 /dev/null /run/nulllinux-live
# The existing Fedora polkit policy can inspect its runtime state type. The
# default var_run_t label denies this guard when polkit spawns it under SELinux.
if [ -e /sys/fs/selinux/enforce ]; then
  chcon -t policykit_var_run_t /run/nulllinux-live
fi
cat >> /home/live/.bash_profile <<'PROF'
# BEGIN NULLLINUX LIVE SESSION
if [ -z "${WAYLAND_DISPLAY:-}" ] && [ "${XDG_VTNR:-}" = 1 ] &&
   /usr/libexec/nulllinux-live-check; then
  exec /opt/nulllinux/bin/null-session
fi
# END NULLLINUX LIVE SESSION
PROF
chown live:live /home/live/.bash_profile
mkdir -p /etc/polkit-1/rules.d
cat > /etc/polkit-1/rules.d/49-nulllinux-live.rules <<'RULE'
polkit.addRule(function(action, subject) {
    if (action.id == "org.fedoraproject.pkexec.liveinst" &&
        subject.user == "live" && subject.active && subject.local) {
        try {
            polkit.spawn(["/usr/libexec/nulllinux-live-check"]);
            return polkit.Result.YES;
        } catch (error) {}
    }
});
RULE
chmod 0644 /etc/polkit-1/rules.d/49-nulllinux-live.rules
SETUP

cat > /etc/systemd/system/nulllinux-live-setup.service <<'LIVESETUP'
[Unit]
Description=Prepare the temporary nullLinux live session
ConditionKernelCommandLine=rd.live.image
After=local-fs.target
Before=getty@tty1.service nulllinux-machine-sync.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/nulllinux-live-setup

[Install]
WantedBy=multi-user.target
LIVESETUP

cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<'AUTO'
[Unit]
Requires=nulllinux-live-setup.service nulllinux-machine-sync.service
After=nulllinux-live-setup.service nulllinux-machine-sync.service

[Service]
# Keep stock agetty's SELinux transition into the login/user domains. A shell
# wrapper here runs in the wrong service domain under enforcing SELinux.
ExecCondition=/usr/libexec/nulllinux-live-check
ExecStart=
ExecStart=-/sbin/agetty --autologin live --noclear %I $TERM
AUTO

cat > /etc/systemd/system/sddm.service.d/live.conf <<'LIVE'
[Unit]
ConditionKernelCommandLine=!rd.live.image
LIVE

# A normal application entry works with the Sway launcher; no desktop-file
# execution permission or desktop-icons component is needed.
cat > /usr/share/applications/install-nulllinux.desktop <<'DESK'
[Desktop Entry]
Type=Application
Name=Install nullLinux
Comment=Install nullLinux on this computer
Exec=/opt/nulllinux/bin/null-live install
Terminal=false
Categories=System;
DESK

# Optional test access is enabled only by a deliberate live-boot argument.
# No authorized key or SSH login exception is included in the base image.
cat > /etc/systemd/system/nulllinux-testkey.service <<'UNIT'
[Unit]
Description=Fetch the explicitly requested live debugging key
ConditionKernelCommandLine=rd.live.image
ConditionKernelCommandLine=nulllinux.sshkey
Requires=nulllinux-live-setup.service
After=nulllinux-live-setup.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/libexec/nulllinux-testkey

[Install]
WantedBy=multi-user.target
UNIT

cat > /usr/libexec/nulllinux-testkey <<'HOOK'
#!/usr/bin/env bash
set -euo pipefail
/usr/libexec/nulllinux-live-check || exit 0
url=$(sed -n 's/.*nulllinux\.sshkey=\([^ ]*\).*/\1/p' /proc/cmdline)
[ -n "$url" ] || exit 0
install -d -m 0700 /root/.ssh
temporary=$(mktemp /root/.ssh/.authorized_keys.XXXXXX)
trap 'rm -f "$temporary"' EXIT
curl -fsS --retry 5 --retry-delay 2 --retry-connrefused -o "$temporary" "$url"
ssh-keygen -l -f "$temporary" >/dev/null
chmod 0600 "$temporary"
mv -f "$temporary" /root/.ssh/authorized_keys
mkdir -p /etc/ssh/sshd_config.d
printf 'PermitRootLogin prohibit-password\n' > /etc/ssh/sshd_config.d/60-nulllinux-test.conf
systemctl restart sshd
HOOK

# Anaconda appends these internal Kickstart post-scripts to the interactive
# install. The default %post context is the installed target's chroot.
cat > /usr/libexec/nulllinux-live-cleanup <<'CLEANUP'
#!/usr/bin/env bash
set -euo pipefail
systemctl --root=/ disable nulllinux-live-setup.service nulllinux-testkey.service
rm -f /etc/systemd/system/getty@tty1.service.d/autologin.conf
rm -f /etc/systemd/system/sddm.service.d/live.conf
rm -f /etc/systemd/system/nulllinux-live-setup.service /etc/systemd/system/nulllinux-testkey.service
rm -f /usr/lib/systemd/system/nulllinux-testkey.service
rm -f /etc/sudoers.d/live-nulllinux /etc/polkit-1/rules.d/49-nulllinux-live.rules
if [ -f /etc/ssh/sshd_config.d/60-nulllinux-test.conf ]; then
  rm -f /root/.ssh/authorized_keys /etc/ssh/sshd_config.d/60-nulllinux-test.conf
fi
rm -f /usr/share/applications/install-nulllinux.desktop
rm -f /run/nulllinux-live /var/lib/nulllinux/surfaces-placed
# Keep Anaconda's newly generated machine-id, but never copy a seed from media.
rm -f /var/lib/systemd/random-seed
# Remove only the blank temporary account. A user explicitly configured as
# "live" by Anaconda has a new password and must survive installation.
if account=$(getent passwd live); then
  password=$(getent shadow live | cut -d: -f2)
  description=$(printf '%s\n' "$account" | cut -d: -f5)
  if [ -z "$password" ] && [ "$description" = "nullLinux Live Session" ]; then
    # The live desktop can still have this UID running outside the target
    # chroot. Remove the copied temporary account despite those live processes.
    userdel --force --remove live
  elif [ -f /home/live/.bash_profile ]; then
    sed -i '/^# BEGIN NULLLINUX LIVE SESSION$/,/^# END NULLLINUX LIVE SESSION$/d' /home/live/.bash_profile
  fi
fi
systemctl --root=/ enable sddm.service nulllinux-machine-sync.service
systemctl --root=/ set-default graphical.target
rm -f /usr/libexec/nulllinux-live-check /usr/libexec/nulllinux-live-setup
rm -f /usr/libexec/nulllinux-live-getty /usr/libexec/nulllinux-testkey
rm -f /usr/share/anaconda/post-scripts/99-nulllinux-live-cleanup.ks
rm -f /usr/libexec/nulllinux-live-cleanup
CLEANUP

# Print section delimiters so the outer compose Kickstart does not consume them.
printf '%s\n' '%post --erroronfail --interpreter=/usr/bin/bash' \
  '/usr/libexec/nulllinux-live-cleanup' '%end' \
  > /usr/share/anaconda/post-scripts/99-nulllinux-live-cleanup.ks
chmod 0755 /usr/libexec/nulllinux-live-{check,setup,cleanup} /usr/libexec/nulllinux-testkey
chmod 0644 /usr/share/applications/install-nulllinux.desktop
systemctl --root=/ enable nulllinux-live-setup.service nulllinux-testkey.service
systemctl --root=/ enable nulllinux-machine-sync.service

# The image records its actual packages and exact Fedora source package names.
# Release review must establish the applicable source-delivery arrangements.
mkdir -p /usr/share/nulllinux
{
  echo "nullLinux source inventory"
  echo "generated $(date -Iseconds) inside the image"
  echo
  echo "Fedora source packages:"
  echo "https://dl.fedoraproject.org/pub/fedora/linux/releases/RELEASEVER/Everything/source/tree/"
  echo "https://dl.fedoraproject.org/pub/fedora/linux/updates/RELEASEVER/Everything/SRPMS/"
  echo "https://kojipkgs.fedoraproject.org/packages/"
  echo
  echo "Retrieve an exact source package with:"
  /opt/nulllinux/bin/pkg source-command
  echo
  echo "nullLinux source and third-party licensing inventory:"
  echo "https://github.com/jamesdanielhomer1/nulllinux"
  echo "/opt/nulllinux/docs/LICENSING.md"
  echo
  echo "MANIFEST -- name-version-release.arch  license  source package"
  /opt/nulllinux/bin/pkg source-manifest
} > /usr/share/nulllinux/SOURCES.txt
sed -i "s|RELEASEVER|$(/opt/nulllinux/bin/pkg distro-version)|g" /usr/share/nulllinux/SOURCES.txt
/opt/nulllinux/bin/null-brand report

# Each live boot must generate its own identity and entropy seed. Preserve the
# Fedora /var/lib/dbus/machine-id symlink to this now-empty machine-id file.
: > /etc/machine-id
rm -f /var/lib/systemd/random-seed
%end
