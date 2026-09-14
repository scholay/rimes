# rime-octagram-data source notice

`grammar.yaml` and the packaged `zh-hans-t-essay-bgw.gram` language model are
from [`lotem/rime-octagram-data`](https://github.com/lotem/rime-octagram-data).

- `grammar.yaml` is pinned to upstream master revision
  `8ceef1b42eb77e86501382a52e85c309c0f2f04c`: 775 bytes; SHA-256
  `a58ce9ef1dc8106634ed305565a832c06ddec9c01796501b1a4adaeb77264129`.
- The Simplified-Chinese model is fetched primarily from upstream Release
  `20260712` as `zh-hans-t-essay-bgw-compact.gram`. Those bytes are identical
  to `zh-hans-t-essay-bgw.gram` at hans branch revision
  `f8ce3b534733e489a8470a7c2adf5a154e8ea069`, which remains the pinned fallback.

- `zh-hans-t-essay-bgw.gram`: 40,925,228 bytes; SHA-256
  `d3cb2438c1fdcd6a855dd6ca8f5c1060a29273c6b64c2c2c69af67cd71b6aa7e`

The upstream repository is distributed under the GNU Lesser General Public
License version 3. A copy of the same LGPL-3.0 text is already packaged at
`rime-data/licenses/rime-easy-en-LICENSE`.
