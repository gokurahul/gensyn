#!/bin/bash

set -euo pipefail

# General env
ROOT=$PWD
export HF_HUB_DOWNLOAD_TIMEOUT=120
DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

GREEN="\033[32m"
BLUE="\033[34m"
RESET="\033[0m"

function echo_green() {
    echo -e "${GREEN}$1${RESET}"
}

function echo_blue() {
    echo -e "${BLUE}$1${RESET}"
}

function cleanup() {
    echo_green ">> Shutting down trainer..."
    kill -- -$$ || true
    exit 0
}

trap cleanup EXIT

# Banner 🚀✨
echo -e "\033[38;5:220m"
cat << "EOF"
 __   __     _ _                            __ ___    __ ___  
 \ \ / /    (_) |                          / // _ \  / // _ \ 
  \ V / __ _ _| | ___  _ __   __ _ ______ / /| (_) |/ /| (_) |
   > < / _` | | |/ _ \| '_ \ / _` |______| '_ \__, | '_ \__, |
  / . \ (_| | | | (_) | | | | (_| |      | (_) |/ /| (_) |/ / 
 /_/ \_\__,_|_|_|\___/|_| |_|\__, |       \___//_/  \___//_/  
                              __/ |                           
                             |___/                            

🐝 Welcome to RL-Swarm! Let's swarm-train some models! 🤖🔥
🙌 Kudos to the amazing Gensyn Team for building this! 💪🎉
EOF

# Prompt user
read -p ">> Connect to the Testnet? [Y/n]: " CONNECT
CONNECT=${CONNECT:-Y}
CONNECT_TO_TESTNET=false
[[ "$CONNECT" =~ ^[Yy]$ ]] && CONNECT_TO_TESTNET=true

read -p ">> Join which Swarm? Math (A) or Math Hard (B)? [A/b]: " CHOICE
CHOICE=${CHOICE:-A}
USE_BIG_SWARM=false
[[ "$CHOICE" =~ ^[Bb]$ ]] && USE_BIG_SWARM=true

read -p ">> How many parameters (in billions)? [0.5, 1.5, 7, 32, 72]: " PARAM_B
PARAM_B=${PARAM_B:-0.5}

SWARM_CONTRACT=$([ "$USE_BIG_SWARM" = true ] && echo "$BIG_SWARM_CONTRACT" || echo "$SMALL_SWARM_CONTRACT")

# Cloudflared logic 🌐
if [ "$CONNECT_TO_TESTNET" = true ]; then
    echo_green ">> Checking Node.js..."
    if ! command -v node > /dev/null; then
        echo "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi

    echo_green ">> Installing Yarn and frontend deps..."
    if ! command -v yarn > /dev/null; then
        npm install -g yarn
    fi
    cd modal-login
    yarn install

    echo_green ">> Starting login server..."
    yarn dev > /dev/null 2>&1 &
    SERVER_PID=$!
    sleep 3
    cd ..

    echo_green ">> Attempting cloudflared tunnel..."
    if ! command -v cloudflared &> /dev/null; then
        echo "Installing cloudflared..."
        wget -q https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb -O cloudflared.deb
        sudo dpkg -i cloudflared.deb
        rm cloudflared.deb
    fi

    cloudflared tunnel --url http://localhost:3000 > cloudflared.log 2>&1 &
    sleep 5

    TUNNEL_URL=$(grep -o 'https://[^ ]*\.trycloudflare.com' cloudflared.log | head -n1)
    if [ -n "$TUNNEL_URL" ]; then
        echo_green ">> Cloudflared is live! Open this in browser:"
        echo_blue "$TUNNEL_URL"
    else
        echo "⚠️  Cloudflared failed. Falling back to local browser..."
        xdg-open http://localhost:3000 || open http://localhost:3000 || echo ">> Open http://localhost:3000 manually."
    fi

    echo_green ">> Waiting for modal userData.json to be created..."
    while [ ! -f "modal-login/temp-data/userData.json" ]; do
        sleep 2
    done

    ORG_ID=$(jq -r '.orgId' modal-login/temp-data/userData.json)
    echo_green ">> ORG_ID detected: $ORG_ID"

    ENV_FILE="$ROOT/modal-login/.env"
    sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"

    echo_green ">> Waiting for API key activation..."
    while true; do
        STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
        [[ "$STATUS" == "activated" ]] && break
        echo "Waiting..."
        sleep 4
    done
fi

# Install Python deps
echo_green ">> Installing Python deps..."
pip install --upgrade pip

if [ -n "${CPU_ONLY:-}" ] || ! command -v nvidia-smi > /dev/null; then
    pip install -r requirements-cpu.txt
    CONFIG_PATH="hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
else
    pip install -r requirements-gpu.txt
    pip install flash-attn --no-build-isolation
    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        *) CONFIG_PATH="hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
    esac
    GAME=$([ "$USE_BIG_SWARM" = true ] && echo "dapo" || echo "gsm8k")
fi

# Hugging Face upload
read -p ">> Push models to Hugging Face? [y/N]: " PUSH_HF
if [[ "$PUSH_HF" =~ ^[Yy]$ ]]; then
    read -p ">> Enter HF token: " HF_TOKEN
else
    HF_TOKEN="None"
fi

# Final launch
echo_green ">> Launching your swarm run... 🐝🔥🤖"
echo_blue ">> Post your progress: https://tinyurl.com/swarmtweet"
echo_blue ">> Star the repo: https://github.com/gensyn-ai/rl-swarm ⭐"

if [ "$CONNECT_TO_TESTNET" = true ]; then
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HF_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --modal_org_id "$ORG_ID" \
        --contract_address "$SWARM_CONTRACT" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
else
    python -m hivemind_exp.gsm8k.train_single_gpu \
        --hf_token "$HF_TOKEN" \
        --identity_path "$IDENTITY_PATH" \
        --config "$CONFIG_PATH" \
        --game "$GAME"
fi

wait # Keep script running until Ctrl+C
