# Contributing

> This file currently covers **testing** only. PR flow, issue process, and
> discussion channels will be added by change #4 (`add-license-contributing`)
> in the v0.1.0 release plan.

## Testing

### Install the test runner

```bash
# Debian/Ubuntu
sudo apt-get install -y bats

# macOS
brew install bats-core

# Any OS with Node.js
npm install -g bats
```

### Run the suite

```bash
bats test/
```

### No submodule step needed

The bats helper libraries (`bats-support` and `bats-assert`) are vendored
under `test/test_helper/`. After a plain `git clone`, just run `bats test/`
— no `git submodule update --init` required.
