# Updating bats-assert

## Upstream

URL: https://github.com/bats-core/bats-assert

## Vendored commit

```
697471b7a89d3ab38571f38c6c7c4b460d1f5e35
```

## How to refresh

Run the following commands to update to the latest HEAD:

```bash
git clone --depth 1 https://github.com/bats-core/bats-assert /tmp/bats-assert
cp -r /tmp/bats-assert/src test/test_helper/bats-assert/
cp /tmp/bats-assert/load.bash test/test_helper/bats-assert/
cp /tmp/bats-assert/LICENSE test/test_helper/bats-assert/
git -C /tmp/bats-assert rev-parse HEAD
```

Record the printed SHA in this file under "Vendored commit", then commit:

```bash
git add test/test_helper/bats-assert/
git commit -m "build(vendor): update bats-assert to <new-sha>"
```

## License

MIT — see LICENSE file in this directory.
