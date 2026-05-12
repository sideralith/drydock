# Updating bats-support

## Upstream

URL: https://github.com/bats-core/bats-support

## Vendored commit

```
0954abb9925cad550424cebca2b99255d4eabe96
```

## How to refresh

Run the following commands to update to the latest HEAD:

```bash
git clone --depth 1 https://github.com/bats-core/bats-support /tmp/bats-support
cp -r /tmp/bats-support/src test/test_helper/bats-support/
cp /tmp/bats-support/load.bash test/test_helper/bats-support/
cp /tmp/bats-support/LICENSE test/test_helper/bats-support/
git -C /tmp/bats-support rev-parse HEAD
```

Record the printed SHA in this file under "Vendored commit", then commit:

```bash
git add test/test_helper/bats-support/
git commit -m "build(vendor): update bats-support to <new-sha>"
```

## License

MIT — see LICENSE file in this directory.
