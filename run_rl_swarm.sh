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

DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}

PINK_TEXT="\033[38;5;213m"
CYAN_TEXT="\033[36m"
GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RESET_TEXT="\033[0m"

print_banner() {
  echo -e "$PINK_TEXT"
  cat << "EOF"
 ____  ___      .__.__                                    ________________  ________________ 
\   \/  /____  |__|  |   ____   ____    ____            /  _____/   __   \/  _____/   __   \
 \     /\__  \ |  |  |  /  _ \ /    \  / ___\   ______ /   __  \\____    /   __  \\____    /
 /     \ / __ \|  |  |_(  <_> )   |  \/ /_/  > /_____/ \  |__\  \  /    /\  |__\  \  /    / 
/___/\  (____  /__|____/\____/|___|  /\___  /           \_____  / /____/  \_____  / /____/  
      \_/    \/                    \//_____/                  \/                \/          
EOF
  echo -e "$CYAN_TEXT      🐝 Welcome to RL-Swarm! Let's swarm-train some models! 🤖🔥"
  echo -e "$GREEN_TEXT      🙌 Kudos to the amazing Gensyn Team for building this! 💪🎉$RESET_TEXT"
}

print_banner

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

cleanup() {
    echo -e "$GREEN_TEXT>> Shutting down trainer...$RESET_TEXT"
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true
    kill -- -$$ || true
    exit 0
}

trap cleanup EXIT

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Would you like to connect to the Testnet? [Y/n] " yn
    echo -en $RESET_TEXT
    yn=${yn:-Y}
    case $yn in
        [Yy]*)  CONNECT_TO_TESTNET=true && break ;;
        [Nn]*)  CONNECT_TO_TESTNET=false && break ;;
        *)  echo ">>> Please answer yes or no." ;;
    esac
done

while true; do
    echo -en $GREEN_TEXT
    read -p ">> Which swarm would you like to join (Math (A) or Math Hard (B))? [A/b] " ab
    echo -en $RESET_TEXT
    ab=${ab:-A}
    case $ab in
        [Aa]*)  USE_BIG_SWARM=false && break ;;
        [Bb]*)  USE_BIG_SWARM=true && break ;;
        *)  echo ">>> Please answer A or B." ;;
    esac
done
if [ "$USE_BIG_SWARM" = true ]; then
    SWARM_CONTRACT="$BIG_SWARM_CONTRACT"
else
    SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
fi

while true; do
    echo -en $GREEN_TEXT
    read -p ">> How many parameters (in billions)? [0.5, 1.5, 7, 32, 72] " pc
    echo -en $RESET_TEXT
    pc=${pc:-0.5}
    case $pc in
        0.5 | 1.5 | 7 | 32 | 72) PARAM_B=$pc && break ;;
        *)  echo ">>> Please answer in [0.5, 1.5, 7, 32, 72]." ;;
    esac
done

if [ "$CONNECT_TO_TESTNET" = true ]; then
    echo "Please login to create an Ethereum Server Wallet"
    cd modal-login

    if ! command -v node > /dev/null 2>&1; then
        echo "Node.js not found. Installing NVM and latest Node.js..."
        export NVM_DIR="$HOME/.nvm"
        if [ ! -d "$NVM_DIR" ]; then
            curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
        fi
        [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
        [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
        nvm install node
    fi

    if ! command -v yarn > /dev/null 2>&1; then
        npm install -g --silent yarn
    fi

    yarn install
    yarn dev > /dev/null 2>&1 &
    SERVER_PID=$!
    sleep 5

    if open http://localhost:3000 2> /dev/null; then
        echo -e "$GREEN_TEXT>> Opened http://localhost:3000 in your browser$RESET_TEXT"
    else
        echo ">> Please open http://localhost:3000 manually"
    fi

    cd ..
    echo -e "$GREEN_TEXT>> Waiting for modal userData.json...$RESET_TEXT"
    for i in {1..30}; do
        [ -f "modal-login/temp-data/userData.json" ] && break
        sleep 5
    done

    if [ ! -f "modal-login/temp-data/userData.json" ]; then
        echo "Timeout waiting for userData.json. Exiting."
        exit 1
    fi

    ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
    echo "Your ORG_ID is set to: $ORG_ID"

    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        [ "$STATUS" == "activated" ] && break
        echo "Waiting for API key to be activated..."
        sleep 5
    done

    ENV_FILE="$ROOT"/modal-login/.env
    if [[ "$OSTYPE" == "darwin"* ]]; then
        sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    else
        sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
    fi
fi

echo -e "$GREEN_TEXT>> Installing Python dependencies...$RESET_TEXT"

pip install --upgrade pip
if [ -n "$CPU_ONLY" ] || ! command -v nvidia-smi &> /dev/null; then
    pip install -r "$ROOT"/requirements-cpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
else
    pip install -r "$ROOT"/requirements-gpu.txt
    pip install flash-attn --no-build-isolation

    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        0.5 | 1.5 | 7) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
    esac

    GAME="$([ "$USE_BIG_SWARM" = true ] && echo "dapo" || echo "gsm8k")"
fi

HF_TOKEN=${HF_TOKEN:-""}
if [ -n "$HF_TOKEN" ]; then
    HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
    echo -en $GREEN_TEXT
    read -p ">> Would you like to push models to Hugging Face? [y/N] " yn
    echo -en $RESET_TEXT
    yn=${yn:-N}
    case $yn in
        [Yy]*) read -p "Enter your Hugging Face access token: " HUGGINGFACE_ACCESS_TOKEN ;;
        *) HUGGINGFACE_ACCESS_TOKEN="None" ;;
    esac
fi

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
