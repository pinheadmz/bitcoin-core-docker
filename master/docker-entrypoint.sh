#!/bin/bash
set -e

if [ -n "${UID+x}" ] && [ "${UID}" != "0" ]; then
  usermod -u "$UID" bitcoin
fi

if [ -n "${GID+x}" ] && [ "${GID}" != "0" ]; then
  groupmod -g "$GID" bitcoin
fi

echo "$0: assuming uid:gid for bitcoin:bitcoin of $(id -u bitcoin):$(id -g bitcoin)"

if [ "$(echo "$1" | cut -c1)" = "-" ]; then
  echo "$0: assuming arguments for bitcoind"
  set -- bitcoind "$@"
fi

if [ "$(echo "$1" | cut -c1)" = "-" ] || [ "$1" = "bitcoind" ]; then
  mkdir -p "$BITCOIN_DATA"
  chmod 700 "$BITCOIN_DATA"
  chown -R bitcoin:bitcoin "$(getent passwd bitcoin | cut -d: -f6)"
  chown -R bitcoin:bitcoin "$BITCOIN_DATA"
  echo "$0: setting data directory to $BITCOIN_DATA"

  set -- "$@" -datadir="$BITCOIN_DATA"

  # Write bitcoin.conf with network section header + user-supplied extra args.
  # BTCPayServer passes all bitcoind config via BITCOIN_EXTRA_ARGS (RPC auth,
  # ZMQ endpoints, ports, whitelist, etc.) and BITCOIN_NETWORK (regtest).
  CONFIG_PREFIX=""
  if [ "${BITCOIN_NETWORK}" = "regtest" ]; then
    CONFIG_PREFIX=$'regtest=1\n[regtest]'
  elif [ "${BITCOIN_NETWORK}" = "testnet" ]; then
    CONFIG_PREFIX=$'testnet=1\n[test]'
  elif [ "${BITCOIN_NETWORK}" = "signet" ]; then
    CONFIG_PREFIX=$'signet=1\n[signet]'
  else
    BITCOIN_NETWORK="mainnet"
    CONFIG_PREFIX=$'[main]'
  fi

  cat <<-EOF > "$BITCOIN_DATA/bitcoin.conf"
${CONFIG_PREFIX}
printtoconsole=1
rpcallowip=::/0
${BITCOIN_EXTRA_ARGS}
EOF
  # Honor BITCOIN_SKIP_WALLET_MIGRATION to suppress the v31.99+ wallet
  # migration restart. Without this, bitcoind exits mid-startup to migrate,
  # and downstream containers (lightningd, lnd, NBXplorer) lose their
  # connection and frequently crash before bitcoind comes back up.
  if [ "${BITCOIN_SKIP_WALLET_MIGRATION}" = "true" ]; then
    echo "nosqlitewalletupgrade=0" >> "$BITCOIN_DATA/bitcoin.conf"
  fi
  chown bitcoin:bitcoin "$BITCOIN_DATA/bitcoin.conf"

  # Auto-create a wallet if none exists. Projects like BTCPayServer/NBXplorer/LND
  # need a wallet available before their services can reach a synced state.
  # bitcoin-wallet v31.99 rejects -wallet="" ("Wallet name cannot be empty"),
  # so we create a named wallet "default" and add it to bitcoin.conf for auto-load.
  WALLET_DIR="$BITCOIN_DATA/wallets"
  if [ "$BITCOIN_NETWORK" != "mainnet" ]; then
    WALLET_DIR="$BITCOIN_DATA/$BITCOIN_NETWORK/wallets"
  fi
  if ! find "$WALLET_DIR" -maxdepth 2 -name wallet.dat 2>/dev/null | grep -q .; then
    echo "$0: no wallet found in $WALLET_DIR, creating default wallet..."
    mkdir -p "$WALLET_DIR"
    chown bitcoin:bitcoin "$(dirname "$WALLET_DIR")" "$WALLET_DIR" 2>/dev/null || true
    gosu bitcoin bitcoin-wallet -datadir="$BITCOIN_DATA" \
      -${BITCOIN_NETWORK:-regtest} -wallet="default" create
    # Add wallet load directive so bitcoind auto-loads the named wallet.
    echo "wallet=default" >> "$BITCOIN_DATA/bitcoin.conf"
  fi
fi

if [ "$1" = "bitcoind" ] || [ "$1" = "bitcoin-cli" ] || [ "$1" = "bitcoin-tx" ]; then
  echo
  exec gosu bitcoin "$@"
fi

echo
exec "$@"
