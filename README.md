# KeyCase Server

Open source cryptographic identity server. Stores and serves identity proofs. Self-hostable.

Part of the [KeyCase](https://github.com/keycase) ecosystem. See the [spec](https://github.com/keycase/spec) for the full vision.

## Quick Start

```bash
# Clone and install dependencies
git clone https://github.com/keycase/keycase.git
cd keycase
dart pub get

# Configure
cp .env.example .env
# Edit .env with your database settings

# Run
dart run bin/server.dart
```

## API

All endpoints are under `/api/v1`.

### Identity

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/identity` | Register a new identity |
| GET | `/api/v1/identity/<username>` | Look up an identity |
| GET | `/api/v1/identity` | Search identities |

### Proofs

| Method | Path | Description |
|--------|------|-------------|
| POST | `/api/v1/proof` | Submit a new proof |
| GET | `/api/v1/proof/<id>` | Get proof status |
| POST | `/api/v1/proof/<id>/verify` | Trigger re-verification |
| GET | `/api/v1/identity/<username>/proofs` | List proofs for identity |

### Health

| Method | Path | Description |
|--------|------|-------------|
| GET | `/health` | Health check |

## Dependencies

- [keycase_core](https://github.com/keycase/core) — shared models and crypto
- PostgreSQL

## License

BSD-3-Clause
