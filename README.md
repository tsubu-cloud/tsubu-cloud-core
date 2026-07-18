# tsubu-cloud-core

tsubu-cloud のコア部分(WASM コンポーネントを実行するホスト、wasmtime/libpq のブリッジ)を切り出した Zig パッケージです。

[`tsubu-cloud`](https://github.com/okuyama-hiroyuki/tsubu-cloud) から `core` モジュールとして依存されます。

## Build

```sh
zig build \
  -Dwasmtime-include=<wasmtime include dir> \
  -Dwasmtime-lib=<wasmtime lib dir> \
  -Dpq-lib=<libpq lib dir> \
  -Dlzma-lib=<liblzma lib dir>
```
