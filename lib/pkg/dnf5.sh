# Package backend: dnf5 / rpm  (Fedora)
#
# THIS FILE AND bin/pkg ARE THE ONLY PLACES IN THIS REPOSITORY THAT MAY NAME A
# PACKAGE MANAGER (NULL.md §9.1). verify/check-package-abstraction.sh enforces
# it. If you find yourself wanting to type "dnf" anywhere else, add a verb here
# instead.

backend_name() { echo "dnf5"; }

backend_detect() { [ -r /etc/fedora-release ] && command -v dnf >/dev/null 2>&1; }

# --- read verbs ---------------------------------------------------------

backend_search() { dnf -q search -- "$@"; }

backend_is_installed() { rpm -q -- "$1" >/dev/null 2>&1; }

# rpm -qf answers from the local database; no network, no metadata needed.
backend_what_owns_this_file() { rpm -qf -- "$1"; }

# --unneeded is the leaf set: installed as a dependency, now required by
# nothing. Empty output and exit 0 means "none", which is a result.
backend_what_is_orphaned() { dnf -q repoquery --unneeded 2>/dev/null; }

# The user-installed set, NOT the full installed set. §8.4 requires this
# distinction: offering every installed package for removal invites removing a
# dependency by hand.
backend_list_explicitly_installed() { dnf -q repoquery --userinstalled 2>/dev/null; }

# Distinct from upgrade: this only refreshes the catalogue. §8.4 depends on
# being able to ask how fresh the metadata is without acting on it.
backend_refresh_metadata() { dnf -q makecache --refresh; }

# Non-mutating. Exit 100 means updates are available, 0 means none.
backend_upgrade_available() { dnf -q check-upgrade >/dev/null 2>&1; [ $? -eq 100 ]; }

# --- mutating verbs -----------------------------------------------------

# INSTALLING WHAT IS ALREADY THERE MUST NOT BE AN ERROR.
#
# dnf5 fails the whole transaction with "Package X is already installed" rather
# than doing nothing, which older dnf did. That makes `install` non-idempotent,
# and an installer that cannot be re-run is an installer nobody can recover a
# half-finished install with -- which is exactly the state a bootstrap is in
# when it fails partway.
#
# So the already-present are filtered out here, and if nothing is left the
# answer is success and a word about it, because "everything you asked for is
# installed" is not a failure in any sense a caller cares about.
backend_install() {
  local want=() p
  for p in "$@"; do
    backend_is_installed "$p" >/dev/null 2>&1 || want+=("$p")
  done
  if [ ${#want[@]} -eq 0 ]; then
    echo "all ${#@} package(s) already installed"
    return 0
  fi
  # NO `--`. This dnf5 rejects it outright: `Unknown argument "--" for command
  # "install"`. It was there to guard against a package name beginning with a
  # dash, which cannot happen in a list this project writes, and it cost a
  # whole install on a machine whose dnf differs from this one's by a few
  # weeks of updates.
  dnf install -y "${want[@]}"
}
backend_remove()  { dnf remove -y "$@"; }
backend_upgrade() { dnf upgrade -y; }

# How many upgrades are pending, against the metadata already on disk.
#
# NO --refresh. Forcing a fetch cost 1.6 s on every open of the update topic,
# and the honest answer to "is this verdict current" is to REPORT THE
# CATALOGUE'S AGE rather than to pay for a refresh nobody asked for -- which is
# the rule §8.4 already states for firmware, applied to packages as well.
backend_upgrade_count() { dnf -q check-upgrade 2>/dev/null | grep -cE '^[a-zA-Z0-9]' || true; }

# Age of the newest repository metadata, in seconds, or nothing if there is
# none. "No metadata" and "metadata saying no updates" are different answers.
backend_metadata_age() {
  local newest=0 t
  while read -r t; do [ "$t" -gt "$newest" ] && newest=$t; done < <(
    find /var/cache/libdnf5 -maxdepth 3 -name repomd.xml -printf '%T@\n' 2>/dev/null | cut -d. -f1)
  [ "$newest" -gt 0 ] || return 1
  echo $(( $(date +%s) - newest ))
}

# Size of the downloaded-package cache, human readable, or "--" if absent.
backend_cache_size() {
  local d=/var/cache/libdnf5
  [ -d "$d" ] && du -sh "$d" 2>/dev/null | cut -f1 || echo "--"
}

backend_remove_orphans() { dnf autoremove -y; }
backend_clean_cache()    { dnf clean packages -y; }

# --- distribution identity and source retrieval -------------------------
#
# These exist so that the image-building tools (null-iso, null-installer-iso,
# null-sources) do not have to name a package manager. Composing an image is a
# different activity from managing packages on a running machine, but §9.1 does
# not care -- one component names the tool, and that component is this one.

backend_distro_version() {
  # The release the running system IS, which is what an image must be built
  # against. Not $releasever from a config file: that can be overridden.
  rpm -q --qf '%{version}' fedora-release-common 2>/dev/null || return 1
}

# Fetch a package's SOURCE. This is what discharges the GPL offer -- see
# bin/null-sources, which uses it to prove the offer resolves to a real srpm
# rather than asserting that it would.
backend_fetch_source() {
  local nvr=$1 dir=$2
  mkdir -p "$dir" || return 1
  dnf download --source --destdir "$dir" "$nvr" >/dev/null 2>&1
}

# One line per installed package: NVRA, licence, source package. This is the
# GPL source manifest (bin/null-sources, the live image's SOURCES.txt), and it
# is here rather than in the kickstart because a different distribution answers
# the same question with a completely different command.
backend_source_manifest() {
  rpm -qa --qf '%{name}-%{version}-%{release}.%{arch}\t%{license}\t%{sourcerpm}\n' | sort
}

backend_count_installed() { rpm -qa | wc -l; }

# How a USER of this image fetches a source package, phrased for this backend.
# Printed into SOURCES.txt, so the offer tells the reader the actual command.
backend_source_command() { echo "dnf download --source <name>-<version>-<release>"; }
