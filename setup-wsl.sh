#!/usr/bin/env bash
# setup-wsl.sh: rebuilds the HRG platform lab workstation inside WSL (Ubuntu 26.04 LTS).
# Safe to re-run: each tool is skipped if the pinned version is already installed.
# Works on arm64 (Windows on ARM) and amd64.
#
# Usage:   ./setup-wsl.sh          install everything
#          ./setup-wsl.sh --check  print installed versions only
set -euo pipefail

# ---- Pinned versions (bump here, commit, re-run) -----------------------------
TFENV_VERSION="v3.2.2"
TERRAFORM_VERSION="1.17.2"     # also written to ~/.terraform-version
KUBECTL_VERSION="v1.36.7"      # keep within one minor version of the AKS cluster
KUBELOGIN_VERSION="v0.2.22"
HELM_VERSION="v4.3.2"
K9S_VERSION="v0.51.0"
KIND_VERSION="v0.33.0"
ARGOCD_VERSION="v3.6.3"
GH_VERSION="2.105.0"
YQ_VERSION="v4.54.3"
TFLINT_VERSION="v0.66.0"
TRIVY_VERSION="0.76.2"
CHECKOV_VERSION="3.4.11"
PRECOMMIT_VERSION="4.7.0"
# az and jq come from apt and are not pinned (az updates itself with `az upgrade`).

BIN=/usr/local/bin
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

case "$(uname -m)" in
  aarch64|arm64) ARCH=arm64; K9S_ARCH=arm64; TRIVY_ARCH=ARM64 ;;
  x86_64)        ARCH=amd64; K9S_ARCH=amd64; TRIVY_ARCH=64bit ;;
  *) echo "Unsupported architecture: $(uname -m)" >&2; exit 1 ;;
esac

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# has_version <command...> -- <expected>: true if the command's output contains the expected version
has_version() {
  local expected="${*: -1}"; local cmd=("${@:1:$#-2}")
  have "${cmd[0]}" || return 1
  local out; out=$("${cmd[@]}" 2>/dev/null) || true   # capture first: grep -q closing the pipe early trips pipefail
  grep -qF -- "${expected#v}" <<<"$out"
}

fetch() { curl -fsSL --retry 3 -o "$2" "$1"; }

install_bin() { sudo install -m 0755 "$1" "$BIN/$2"; echo "installed $2"; }

check() {
  hash -r   # forget cached command paths so freshly installed binaries are the ones reported
  log "Installed versions ($ARCH)"
  local c out
  for c in "az version -o tsv --query '\"azure-cli\"'" "terraform version" "kubectl version --client" \
           "kubelogin --version" "helm version --short" "k9s version --short" "kind version" \
           "argocd version --client --short" "gh --version" "jq --version" "yq --version" \
           "tflint --version" "checkov --version" "trivy --version" "pre-commit --version" \
           "docker --version" "docker compose version"; do
    printf '%-14s ' "${c%% *}"
    if out=$(eval "$c" 2>/dev/null) && [[ -n "$out" ]]; then
      # first line that contains a version number (kubelogin prints a header line first)
      grep -m1 -E '[0-9]+\.[0-9]+' <<<"$out" || head -1 <<<"$out"
    else
      echo "MISSING"
    fi
  done
  echo
  echo "Binaries found more than once on PATH (the first one wins):"
  for b in az terraform kubectl helm gh jq yq; do
    # dedupe by inode, because /bin is a symlink to /usr/bin on Ubuntu
    local paths; paths=$(type -ap "$b" | while read -r f; do echo "$(stat -L -c '%d:%i' "$f") $f"; done | awk '!seen[$1]++ {print $2}')
    [[ $(grep -c . <<<"$paths") -gt 1 ]] && echo "  $b: $(tr '\n' ' ' <<<"$paths")"
  done
  return 0
}

if [[ "${1:-}" == "--check" ]]; then check; exit 0; fi

# ---- Base packages ------------------------------------------------------------
log "apt base packages"
sudo apt-get update -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release unzip git jq bash-completion pipx

# ---- Azure CLI (Microsoft apt repo) ------------------------------------------
if ! have az; then
  log "Azure CLI"
  sudo mkdir -p /etc/apt/keyrings
  curl -fsSL https://packages.microsoft.com/keys/microsoft.asc | gpg --dearmor | sudo tee /etc/apt/keyrings/microsoft.gpg >/dev/null
  echo "Types: deb
URIs: https://packages.microsoft.com/repos/azure-cli/
Suites: $(lsb_release -cs)
Components: main
Architectures: $(dpkg --print-architecture)
Signed-by: /etc/apt/keyrings/microsoft.gpg" | sudo tee /etc/apt/sources.list.d/azure-cli.sources >/dev/null
  sudo apt-get update -y && sudo apt-get install -y azure-cli
fi

# ---- Docker Engine inside WSL (no Docker Desktop) -----------------------------
# WSL needs systemd for the docker service. Ubuntu's WSL images enable it by default; make sure.
if ! grep -qs '^systemd=true' /etc/wsl.conf; then
  log "enable systemd in /etc/wsl.conf"
  printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null
  NEED_WSL_RESTART=1
fi
if ! dpkg -s docker-ce >/dev/null 2>&1; then
  log "Docker Engine"
  # remove Ubuntu's unofficial packages that clash with Docker's own
  for p in docker.io docker-compose docker-compose-v2 docker-doc podman-docker containerd runc; do
    if dpkg -s "$p" >/dev/null 2>&1; then sudo apt-get remove -y "$p"; fi
  done
  sudo install -m 0755 -d /etc/apt/keyrings
  sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  sudo chmod a+r /etc/apt/keyrings/docker.asc
  echo "Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: /etc/apt/keyrings/docker.asc" | sudo tee /etc/apt/sources.list.d/docker.sources >/dev/null
  sudo apt-get update -y
  sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
if ! id -nG "$USER" | grep -qw docker; then
  sudo usermod -aG docker "$USER"   # run docker without sudo (takes effect in a new WSL session)
  NEED_WSL_RESTART=1
fi
if [[ -d /run/systemd/system ]]; then
  sudo systemctl enable --now docker >/dev/null 2>&1 || true
fi

# ---- Terraform via tfenv ------------------------------------------------------
if [[ ! -d "$HOME/.tfenv" ]]; then
  log "tfenv $TFENV_VERSION"
  git clone --depth 1 --branch "$TFENV_VERSION" https://github.com/tfutils/tfenv.git "$HOME/.tfenv"
fi
export PATH="$HOME/.tfenv/bin:$PATH"
echo "$TERRAFORM_VERSION" > "$HOME/.terraform-version"
if ! has_version terraform version -- "$TERRAFORM_VERSION"; then
  log "terraform $TERRAFORM_VERSION"
  tfenv install "$TERRAFORM_VERSION" && tfenv use "$TERRAFORM_VERSION"
fi

# ---- Single-binary tools ------------------------------------------------------
if ! has_version kubectl version --client -- "$KUBECTL_VERSION"; then
  log "kubectl $KUBECTL_VERSION"
  fetch "https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/$ARCH/kubectl" "$TMP/kubectl"
  install_bin "$TMP/kubectl" kubectl
fi

if ! has_version kubelogin --version -- "$KUBELOGIN_VERSION"; then
  log "kubelogin $KUBELOGIN_VERSION"
  fetch "https://github.com/Azure/kubelogin/releases/download/$KUBELOGIN_VERSION/kubelogin-linux-$ARCH.zip" "$TMP/kl.zip"
  unzip -oq "$TMP/kl.zip" -d "$TMP/kl"
  install_bin "$TMP/kl/bin/linux_$ARCH/kubelogin" kubelogin
fi

if ! has_version helm version --short -- "$HELM_VERSION"; then
  log "helm $HELM_VERSION"
  fetch "https://get.helm.sh/helm-$HELM_VERSION-linux-$ARCH.tar.gz" "$TMP/helm.tgz"
  tar -xzf "$TMP/helm.tgz" -C "$TMP"
  install_bin "$TMP/linux-$ARCH/helm" helm
fi

if ! has_version k9s version --short -- "$K9S_VERSION"; then
  log "k9s $K9S_VERSION"
  fetch "https://github.com/derailed/k9s/releases/download/$K9S_VERSION/k9s_Linux_$K9S_ARCH.tar.gz" "$TMP/k9s.tgz"
  tar -xzf "$TMP/k9s.tgz" -C "$TMP" k9s
  install_bin "$TMP/k9s" k9s
fi

if ! has_version kind version -- "$KIND_VERSION"; then
  log "kind $KIND_VERSION"
  fetch "https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION/kind-linux-$ARCH" "$TMP/kind"
  install_bin "$TMP/kind" kind
fi

if ! has_version argocd version --client --short -- "$ARGOCD_VERSION"; then
  log "argocd $ARGOCD_VERSION"
  fetch "https://github.com/argoproj/argo-cd/releases/download/$ARGOCD_VERSION/argocd-linux-$ARCH" "$TMP/argocd"
  install_bin "$TMP/argocd" argocd
fi

if ! has_version gh --version -- "$GH_VERSION"; then
  log "gh $GH_VERSION"
  fetch "https://github.com/cli/cli/releases/download/v$GH_VERSION/gh_${GH_VERSION}_linux_$ARCH.tar.gz" "$TMP/gh.tgz"
  tar -xzf "$TMP/gh.tgz" -C "$TMP"
  install_bin "$TMP/gh_${GH_VERSION}_linux_$ARCH/bin/gh" gh
fi

if ! has_version yq --version -- "$YQ_VERSION"; then
  log "yq $YQ_VERSION"
  fetch "https://github.com/mikefarah/yq/releases/download/$YQ_VERSION/yq_linux_$ARCH" "$TMP/yq"
  install_bin "$TMP/yq" yq
fi

if ! has_version tflint --version -- "$TFLINT_VERSION"; then
  log "tflint $TFLINT_VERSION"
  fetch "https://github.com/terraform-linters/tflint/releases/download/$TFLINT_VERSION/tflint_linux_$ARCH.zip" "$TMP/tflint.zip"
  unzip -oq "$TMP/tflint.zip" -d "$TMP"
  install_bin "$TMP/tflint" tflint
fi

if ! has_version trivy --version -- "$TRIVY_VERSION"; then
  log "trivy $TRIVY_VERSION"
  fetch "https://github.com/aquasecurity/trivy/releases/download/v$TRIVY_VERSION/trivy_${TRIVY_VERSION}_Linux-$TRIVY_ARCH.tar.gz" "$TMP/trivy.tgz"
  tar -xzf "$TMP/trivy.tgz" -C "$TMP" trivy
  install_bin "$TMP/trivy" trivy
fi

# ---- Python tools (isolated with pipx) ---------------------------------------
pipx ensurepath >/dev/null 2>&1 || true
export PATH="$HOME/.local/bin:$PATH"
has_version checkov --version -- "$CHECKOV_VERSION" || { log "checkov $CHECKOV_VERSION"; pipx install --force "checkov==$CHECKOV_VERSION"; }
has_version pre-commit --version -- "$PRECOMMIT_VERSION" || { log "pre-commit $PRECOMMIT_VERSION"; pipx install --force "pre-commit==$PRECOMMIT_VERSION"; }

# ---- Shell config: one managed block in ~/.bashrc ----------------------------
log "~/.bashrc aliases and completion"
MARK_BEGIN="# >>> hrg-lab setup-wsl >>>"
MARK_END="# <<< hrg-lab setup-wsl <<<"
sed -i "/$MARK_BEGIN/,/$MARK_END/d" "$HOME/.bashrc"
cat >> "$HOME/.bashrc" <<EOF
$MARK_BEGIN
export PATH="\$HOME/.tfenv/bin:\$HOME/.local/bin:\$PATH"
source <(kubectl completion bash)
source <(helm completion bash)
source <(gh completion -s bash)
alias k=kubectl
complete -o default -F __start_kubectl k
alias tf=terraform
alias kctx='kubectl config use-context'
alias kns='kubectl config set-context --current --namespace'
alias kgp='kubectl get pods -o wide'
$MARK_END
EOF

check
if [[ "${NEED_WSL_RESTART:-0}" == 1 ]]; then
  log "Restart WSL to finish: in PowerShell run 'wsl --shutdown', then open Ubuntu again and run 'docker run --rm hello-world'."
else
  log "Done. Run 'source ~/.bashrc' or open a new terminal."
fi
