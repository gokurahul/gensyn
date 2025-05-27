#!/bin/bash

set -euo pipefail

# ====== Color Codes ======
RESET="\033[0m"
BOLD="\033[1m"
DIM="\033[2m"
UNDERLINE="\033[4m"

# Text colors
RED="\033[31m"
GREEN="\033[32m"
YELLOW="\033[33m"
BLUE="\033[34m"
MAGENTA="\033[35m"
CYAN="\033[36m"
WHITE="\033[97m"
ORANGE="\033[38;5;208m"
PINK="\033[38;5;213m"

# ====== Color Functions ======
info()    { echo -e "${CYAN}${1}${RESET}"; }
success() { echo -e "${GREEN}${1}${RESET}"; }
warn()    { echo -e "${YELLOW}${1}${RESET}"; }
error()   { echo -e "${RED}${1}${RESET}" >&2; }
question(){ echo -en "${MAGENTA}${1}${RESET}"; }
section() { echo -e "${ORANGE}========================= ${1} =========================${RESET}"; }

# ====== Modern/Boxy Banner Style ======
banner() {
  echo -e "${BOLD}${CYAN}"
  echo "╭──────────────────────────────────────────────────────────────────────────────╮"
  echo "│   ${YELLOW}██████╗ ██╗      ███████╗██╗       ███████╗██╗    ██╗ █████╗ ███╗   ███╗${CYAN} │"
  echo "│   ${YELLOW}██╔══██╗██║      ██╔════╝██║       ██╔════╝██║    ██║██╔══██╗████╗ ████║${CYAN} │"
  echo "│   ${YELLOW}██████╔╝██║      █████╗  ██║       █████╗  ██║ █╗ ██║███████║██╔████╔██║${CYAN} │"
  echo "│   ${YELLOW}██╔══██╗██║      ██╔══╝  ██║       ██╔══╝  ██║███╗██║██╔══██║██║╚██╔╝██║${CYAN} │"
  echo "│   ${YELLOW}██████╔╝███████╗███████╗███████╗   ██║     ╚███╔███╔╝██║  ██║██║ ╚═╝ ██║${CYAN} │"
  echo "│   ${YELLOW}╚═════╝ ╚══════╝╚══════╝╚══════╝   ╚═╝      ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝     ╚═╝${CYAN} │"
  echo "│                                                                              │"
  echo "│   ${MAGENTA}🐝 Welcome to RL-Swarm — Swarm-Train Your Models! 🤖🔥${CYAN}                      │"
  echo "│   ${GREEN}🙌 Powered by the amazing Gensyn Team! 💪🎉${CYAN}                                  │"
  echo "╰──────────────────────────────────────────────────────────────────────────────╯"
  echo -e "${RESET}"
}

# ====== Usage ======
usage() {
  echo -e "${BOLD}${WHITE}Usage:${RESET} ./run_rl_swarm.sh [--help] [--dry-run]"
  echo "    --help        Show this help message and exit"
  echo "    --dry-run     Preview actions without executing them"
  exit 0
}

# ====== Parse Arguments ======
DRY_RUN=0
for arg in "$@"; do
  case $arg in
    -h|--help) usage ;;
    --dry-run) DRY_RUN=1; shift ;;
    *) error "Unknown argument: $arg"; usage ;;
  esac
done

# ====== Print Banner ======
banner
section "Script Start"

ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

# ====== Set Defaults ======
DEFAULT_PUB_MULTI_ADDRS=""
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ"
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem

PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

CPU_ONLY=${CPU_ONLY:-""}
ORG_ID=${ORG_ID:-""}

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ====== Cleanup Function ======
cleanup() {
  warn ">> Shutting down trainer..."
  rm -rf "$ROOT_DIR/modal-login/temp-data/"*.json 2>/dev/null || true
  kill -- -$$ 2>/dev/null || true
  exit 0
}
trap cleanup EXIT

# ====== DRY RUN ======
if [[ $DRY_RUN -eq 1 ]]; then
  warn "[DRY RUN MODE IS ACTIVE]"
fi

# ====== Prompt Functions ======
prompt_yes_no() {
  local prompt="$1"
  local default="$2"
  local yn
  while true; do
    question "$prompt [$default] "
    read yn
    yn=${yn:-$default}
    case $yn in
      [Yy]*) return 0 ;;
      [Nn]*) return 1 ;;
      *) warn ">>> Please answer yes or no." ;;
    esac
  done
}

prompt_choice() {
  local prompt="$1"
  local default="$2"
  local choices="$3"
  local resp
  while true; do
    question "$prompt [$default] "
    read resp
    resp=${resp:-$default}
    if [[ "$choices" == *"$resp"* ]]; then
      echo "$resp"
      return 0
    else
      warn ">>> Please answer in [$choices]."
    fi
  done
}

# ====== Prompts ======
section "Configuration"
if prompt_yes_no ">> Would you like to connect to the Testnet?" "Y"; then
  CONNECT_TO_TESTNET=true
else
  CONNECT_TO_TESTNET=false
fi

SWARM_CHOICE=$(prompt_choice ">> Which swarm would you like to join (Math (A) or Math Hard (B))?" "A" "AaBb")
if [[ "$SWARM_CHOICE" =~ [Bb] ]]; then
  USE_BIG_SWARM=true
else
  USE_BIG_SWARM=false
fi
SWARM_CONTRACT="$([[ "$USE_BIG_SWARM" = true ]] && echo "$BIG_SWARM_CONTRACT" || echo "$SMALL_SWARM_CONTRACT")"

PARAM_B=$(prompt_choice ">> How many parameters (in billions)?" "0.5" "0.5 1.5 7 32 72")

if [[ $DRY_RUN -eq 1 ]]; then
  warn "[DRY RUN] Would process connect to testnet: $CONNECT_TO_TESTNET, swarm: $SWARM_CONTRACT, params: $PARAM_B"
  exit 0
fi

# ====== Testnet Logic ======
if [[ "$CONNECT_TO_TESTNET" == true ]]; then
  section "Ethereum Server Wallet Setup"
  info "Please login to create an Ethereum Server Wallet"
  cd modal-login

  if ! command -v node >/dev/null 2>&1; then
    warn "Node.js not found. Installing NVM and latest Node.js..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
      curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm install node
  fi

  if ! command -v yarn >/dev/null 2>&1; then
    npm install -g --silent yarn
  fi

  yarn install
  yarn dev >/dev/null 2>&1 &
  SERVER_PID=$!
  sleep 5

  if open http://localhost:3000 2>/dev/null; then
    success ">> Opened http://localhost:3000 in your browser"
  else
    warn ">> Please open http://localhost:3000 manually"
  fi

  cd ..
  info ">> Waiting for modal userData.json..."
  for i in {1..30}; do
    [ -f "modal-login/temp-data/userData.json" ] && break
    sleep 5
  done

  if [ ! -f "modal-login/temp-data/userData.json" ]; then
    error "Timeout waiting for userData.json. Exiting."
    exit 1
  fi

  ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
  info "Your ORG_ID is set to: $ORG_ID"

  while true; do
    STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
    [[ "$STATUS" == "activated" ]] && break
    info "Waiting for API key to be activated..."
    sleep 5
  done

  ENV_FILE="$ROOT"/modal-login/.env
  if [[ "$OSTYPE" == "darwin"* ]]; then
    sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
  else
    sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
  fi
fi

# ====== Python Dependency Installation ======
section "Python Setup"
success ">> Installing Python dependencies..."

pip install --upgrade pip
if [ -n "$CPU_ONLY" ] || ! command -v nvidia-smi &>/dev/null; then
  pip install -r "$ROOT"/requirements-cpu.txt
  CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
  GAME="gsm8k"
else
  pip install -r "$ROOT"/requirements-gpu.txt
  pip install flash-attn --no-build-isolation
  case "$PARAM_B" in
    32|72) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-bnb-4bit-deepseek-r1.yaml" ;;
    0.5|1.5|7) CONFIG_PATH="$ROOT/hivemind_exp/configs/gpu/grpo-qwen-2.5-${PARAM_B}b-deepseek-r1.yaml" ;;
  esac
  GAME="$([[ "$USE_BIG_SWARM" = true ]] && echo "dapo" || echo "gsm8k")"
fi

# ====== Hugging Face Token ======
section "Hugging Face"
HF_TOKEN=${HF_TOKEN:-""}
if [ -n "$HF_TOKEN" ]; then
  HUGGINGFACE_ACCESS_TOKEN=${HF_TOKEN}
else
  if prompt_yes_no ">> Would you like to push models to Hugging Face?" "N"; then
    question "Enter your Hugging Face access token: "
    read HUGGINGFACE_ACCESS_TOKEN
  else
    HUGGINGFACE_ACCESS_TOKEN="None"
  fi
fi

# ====== Final Training Launch ======
section "RL-Swarm Training"
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

section "RL-Swarm is running! Press Ctrl+C to stop."
wait # Keep script running until Ctrl+C
