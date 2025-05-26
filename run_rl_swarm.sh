#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

# Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

# Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

# Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to RSA private key (creates new if not found)
DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}

PINK="\033[38;5;213m"
GREEN="\033[32m"
CYAN="\033[36m"
RESET="\033[0m"

echo_pink() {
  echo -e "$PINK$1$RESET"
}

echo_green() {
  echo -e "$GREEN$1$RESET"
}

echo_cyan() {
  echo -e "$CYAN$1$RESET"
}

trap 'echo_green "\n>> Cleaning up..."; kill -- -$$ || true' EXIT

clear
echo_pink "
 ____  ___      .__.__                                    ________________  ________________ 
\\   \\/  /____  |__|  |   ____   ____    ____            /  _____/   __   \\/  _____/   __   \\
 \\     /\\__  \\ |  |  |  /  _ \\ /    \\  / ___\\   ______ /   __  \\\\____    /   __  \\\\____    /
 /     \\ / __ \\|  |  |_(  <_> )   |  \\/ /_/  > /_____/ \\  |__\\  \\  /    /\\  |__\\  \\  /    / 
/___/\\  (____  /__|____/\\____/|___|  /\\___  /           \\_____  / /____/  \\_____  / /____/  
      \\_/    \/                    \\/_____/                  \\/                \\/           
"

echo_cyan "      🐝 Welcome to RL-Swarm! Let's swarm-train some models! 🤖🔥"
echo_green "      👋 Kudos to the amazing Gensyn Team for building this! 💪🎉"

CONNECT_TO_TESTNET=true
USE_BIG_SWARM=false
PARAM_B=0.5
SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
GAME="gsm8k"

if [ "$CONNECT_TO_TESTNET" = true ]; then
  echo_green ">> Setting up modal-login silently..."
  cd modal-login

  if ! command -v node > /dev/null; then
    echo_green ">> Installing Node.js (via NVM)..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    source "$NVM_DIR/nvm.sh"
    nvm install node
  fi

  if ! command -v yarn > /dev/null; then
    npm install -g yarn > /dev/null 2>&1
  fi

  yarn install > /dev/null 2>&1
  yarn dev > /dev/null 2>&1 &
  SERVER_PID=$!
  echo_green ">> Modal login server started in background. PID: $SERVER_PID"
  echo "\n📝 Please open http://localhost:3000 manually in your browser to complete the login."

  cd ..
  echo_green ">> Waiting for userData.json to appear..."
  for i in {1..60}; do
    if [ -f modal-login/temp-data/userData.json ]; then
      echo_green ">> Found userData.json"
      break
    fi
    sleep 2
  done

  ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
  echo_green ">> ORG_ID = $ORG_ID"

  echo_green ">> Waiting for API key activation..."
  while true; do
    STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
    if [[ "$STATUS" == "activated" ]]; then
      echo_green ">> API key activated!"
      break
    fi
    sleep 3
  done

  ENV_FILE="$ROOT/modal-login/.env"
  sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
fi

# Install Python requirements
pip install --upgrade pip > /dev/null
if [ -n "$CPU_ONLY" ] || ! command -v nvidia-smi &> /dev/null; then
  pip install -r "$ROOT/requirements-cpu.txt" > /dev/null
  CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
else
  pip install -r "$ROOT/requirements-gpu.txt" > /dev/null
  pip install flash-attn --no-build-isolation > /dev/null
  CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml"
fi

HUGGINGFACE_ACCESS_TOKEN="None"
echo_green ">> Launching training..."

if [ -n "$ORG_ID" ]; then
  python -m hivemind_exp.gsm8k.train_single_gpu \
    --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
    --identity_path "$IDENTITY_PATH" \
    --modal_org_id "$ORG_ID" \
    --contract_address "$SWARM_CONTRACT" \
    --config "$CONFIG_PATH" \
    --game "$GAME"
else
  python -m hivemind_exp.gsm8k.train_single_gpu \
    --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
    --identity_path "$IDENTITY_PATH" \
    --public_maddr "$PUB_MULTI_ADDRS" \
    --initial_peers "$PEER_MULTI_ADDRS" \
    --host_maddr "$HOST_MULTI_ADDRS" \
    --config "$CONFIG_PATH" \
    --game "$GAME"
fi

wait # Keep script running until Ctrl+C
