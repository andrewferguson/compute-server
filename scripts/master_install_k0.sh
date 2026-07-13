#!/usr/bin/env bash
set -euo pipefail
LOG_FILE="$HOME/k0s_master.log"
if [ ! -f "/tmp/common_k0.sh" ]; then
  cp /local/repository/scripts/common_k0.sh /tmp/common_k0.sh
fi
source /tmp/common_k0.sh

install_deps
install_k0s

# Update the hostname (used as node name in k8s)
until sudo hostnamectl set-hostname "controller"
do
  echo "Failed to set hostname..."
  sleep 5
done

log "Installing controller service"
k0s config create > $HOME/k0s.yaml
sed -i 's/^    provider: kuberouter$/    provider: custom/' $HOME/k0s.yaml
sed -i 's/^  controllerManager: {}/  controllerManager:\n    extraArgs:\n      node-monitor-grace-period: 50000s/g' $HOME/k0s.yaml
log "configuring controller"
sudo k0s install controller -c $HOME/k0s.yaml --enable-worker --kubelet-extra-args="--max-pods=243 --resolv-conf=/run/systemd/resolve/resolv.conf"
sleep 1
log "starting k0s"
sudo k0s start

dest=$HOME/token-file   # final location
delay=5                        # seconds between attempts

while :; do
  echo "⇒ Requesting worker token …"
  token=$(sudo k0s token create --role=worker --expiry=100h || true)

  if [[ -n $token ]]; then           # non-empty?
    printf '%s\n' "$token" > "$dest"
    echo "✓ Token saved to $dest"
    break
  else
    echo "⚠️  k0s returned an empty token; retrying in $delay s …"
    sleep "$delay"
  fi
done
sudo k0s kubectl apply -f https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
sudo cp /var/lib/k0s/pki/admin.conf ~/admin.conf
cat > ~/.chronos <<'EOF'
export KUBECONFIG=~/admin.conf
EOF
grep -qxF '[ -f ~/.chronos ] && source ~/.chronos' ~/.bashrc || echo '[ -f ~/.chronos ] && source ~/.chronos' >> ~/.bashrc
sudo chown $USER ~/admin.conf
chmod g-r ~/admin.conf
sudo wget https://github.com/mikefarah/yq/releases/latest/download/yq_linux_amd64 -O /usr/bin/yq && sudo chmod +x /usr/bin/yq
echo -e '#!/bin/bash\nexec k0s kubectl "$@"' | sudo tee /usr/local/bin/kubectl > /dev/null
sudo chmod +x /usr/local/bin/kubectl
KUBECONFIG=~/admin.conf kubectl taint nodes ins0vm node-role.kubernetes.io/control-plane-
#Generate and save Worker token
log "Worker join-token written to $HOME/token-file"
