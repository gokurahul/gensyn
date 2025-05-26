#!/bin/bash

set -euo pipefail

# Define colors for output (magenta and cyan for banner + neat colors)
MAGENTA="\033[38;5;201m"
CYAN="\033[38;5;45m"
GREEN="\033[38;5;34m"
BLUE="\033[38;5;27m"
SAFFRON="\033[38;5;208m"
WHITE="\033[97m"
RESET="\033[0m"

function echo_magenta() {
    echo -e "${MAGENTA}$1${RESET}"
}
function echo_cyan() {
    echo -e "${CYAN}$1${RESET}"
}
function echo_green() {
    echo -e "${GREEN}$1${RESET}"
}
function echo_blue() {
    echo -e "${BLUE}$1${RESET}"
}
function echo_saffron() {
    echo -e "${SAFFRON}$1${RESET}"
}

# Cleanup function to kill background jobs on exit
function cleanup() {
    echo_green ">> Shutting down trainer..."
    kill -- -$$ || true
    exit 0
}
trap cleanup EXIT

# Clear and print banner
clear
echo_magenta "
____  ___      .__.__                                    ________________  ________________ 
\\   \\/  /____  |__|  |   ____   ____    ____            /  _____/   __   \\/  _____/   __   \\
 \\     /\\__  \\ |  |  |  /  _ \\ /    \\  / ___\\   ______ /   __  \\\\____    /   __  \\\\____    /
 /     \\ / __ \\|  |  |_(  <_> )   |  \\/ /_/  > /_____/ \\  |__\\  \\  /    /\\  |__\\  \\  /    / 
/___/\\  (____  /__|____/\\____/|___|  /\\___  /           \\_____  / /____/  \\_____  / /____/  
      \\_/    \\/                    \\//_____/                  \\/                \\/           
"

echo_cyan "      🐝 Welcome to RL-Swarm! Let's swarm-train some models! 🤖🔥"
echo_green "      🙌 Kudos to the amazing Gensyn Team for building this! 💪🎉"

# Prompt user for testnet connection
read -rp ">> Connect to the Testnet? [Y/n]: " CONNECT
CONNECT=${CONNECT:-Y}
CONNECT_TO_TESTNET=false
[[ "$CONNECT" =~ ^[Yy]$ ]] && CONNECT_TO_TESTNET=true

# Prompt user for swarm choice
read -rp ">> Join which Swarm? Math (A) or Math Hard (B)? [A/b]: " CHOICE
CHOICE=${CHOICE:-A}
USE_BIG_SWARM=false
[[ "$CHOICE" =~ ^[Bb]$ ]] && USE_BIG_SWARM=true

# Prompt user for parameter size
read -rp ">> How many parameters (in billions)? [0.5, 1.5, 7, 32, 72]: " PARAM_B
PARAM_B=${PARAM_B:-0.5}

# Contract addresses
SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"
SWARM_CONTRACT=$([ "$USE_BIG_SWARM" = true ] && echo "$BIG_SWARM_CONTRACT" || echo "$SMALL_SWARM_CONTRACT")

# Identity path
ROOT=$PWD
DEFAULT_IDENTITY_PATH="$ROOT/swarm.pem"
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

if [ "$CONNECT_TO_TESTNET" = true ]; then
    echo_green ">> Checking Node.js..."
    if ! command -v node > /dev/null; then
        echo "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi

    echo_green ">> Installing Yarn and frontend dependencies..."
    if ! command -v yarn > /dev/null; then
        npm install -g yarn
    fi

    # Remove package-lock.json to avoid conflicts
    rm -f modal-login/package-lock.json

    cd modal-login
    yarn install --silent

    echo_green ">> Starting login server (local tunnel)..."
    yarn dev > /dev/null 2>&1 &
    SERVER_PID=$!
    sleep 3
    cd ..

    # Install localtunnel if not installed
    if ! command -v lt > /dev/null; then
        echo_green ">> Installing localtunnel CLI..."
        npm install -g localtunnel
    fi

    echo_green ">> Attempting localtunnel..."
    LT_TUNNEL_URL=""
    LT_PID=""
    # Run localtunnel in background and capture URL
    lt --port 3000 --print-requests > lt.log 2>&1 &
    LT_PID=$!

    # Wait for localtunnel URL to appear in lt.log (max 15 sec)
    for i in {1..15}; do
        LT_TUNNEL_URL=$(grep -o 'https://[-a-z0-9]*\.loca.lt' lt.log | head -n1 || true)
        if [ -n "$LT_TUNNEL_URL" ]; then
            break
        fi
        sleep 1
    done

    if [ -n "$LT_TUNNEL_URL" ]; then
        echo_green ">> Localtunnel is live! Open this in browser:"
        echo_blue "$LT_TUNNEL_URL"
    else
        echo_saffron "⚠️  Localtunnel failed or took too long."
        echo_green ">> Attempting cloudflared tunnel (Cloudflare tunnel)..."
        # Kill localtunnel if running
        if [ -n "$LT_PID" ]; then
            kill "$LT_PID" || true
        fi

        if ! command -v cloudflared &> /dev/null; then
            echo_green ">> Installing cloudflared..."
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
            echo_saffron "⚠️  Cloudflared failed."
            echo_green ">> Falling back to local browser open..."
            xdg-open http://localhost:3000 || open http://localhost:3000 || echo ">> Open http://localhost:3000 manually."
        fi
    fi

    echo_green ">> Waiting for modal userData.json to be created..."
    for i in {1..30}; do
        if [ -f "modal-login/temp-data/userData.json" ]; then
            break
        fi
        sleep 2
    done

    if [ ! -f "modal-login/temp-data/userData.json" ]; then
        echo -e "\033[91m❌ Failed to retrieve ORG_ID. Please retry login.\033[0m"
        exit 1
    fi

    ORG_ID=$(jq -r '.orgId' modal-login/temp-data/userData.json)
    if [ "$ORG_ID" = "null" ]; then
        echo -e "\033[91m❌ ORG_ID is null. Login failed.\033[0m"
        exit 1
    fi
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

# Install Python dependencies silently
echo_green ">> Installing Python dependencies..."
pip install --upgrade pip -q

if [ -n "${CPU_ONLY:-}" ] || ! command -v nvidia-smi > /dev/null; then
    pip install -r requirements-cpu.txt -q
    CONFIG_PATH="hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
else
    pip install -r requirements-gpu.txt -q
    pip install flash-attn --no-build-isolation -q
    case "$PARAM_B" in
        32 | 72) CONFIG_PATH="hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
        *) CONFIG_PATH="hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
    esac
    GAME=$([ "$USE_BIG_SWARM" = true ] && echo "dapo" || echo "gsm8k")
fi

# Prompt for Hugging Face token
read -rp ">> Push models to Hugging Face? [y/N]: " PUSH_HF
if [[ "$PUSH_HF" =~ ^[Yy]$ ]]; then
    read -rp ">> Enter HF token: " HF_TOKEN
else
    HF_TOKEN="None"
fi

# Launch training
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
