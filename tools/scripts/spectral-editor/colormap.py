"""The magma colour map, 256 entries of RGB (768 bytes).

The values are those of matplotlib's `magma` (Nathaniel J. Smith, Stefan van der Walt, Eric Firing;
released under CC0 1.0, public domain dedication). Generated once, in a throwaway environment, with
`np.rint(matplotlib.cm.magma(np.linspace(0, 1, 256))[:, :3] * 255)`; matplotlib is NOT a dependency
and nothing here imports it. `test_fixture.py` pins the first, middle and last entries.
"""

_HEX = (
    "00000401000501010601010802010902020b02020d03030f"
    "03031204041405041606051806051a07061c08071e090720"
    "0a08220b09240c09260d0a290e0b2b100b2d110c2f120d31"
    "130d34140e36150e38160f3b180f3d19103f1a10421c1044"
    "1d11471e114920114b21114e221150241253251255271258"
    "29115a2a115c2c115f2d11612f1163311165331067341069"
    "36106b38106c390f6e3b0f703d0f713f0f72400f74420f75"
    "440f764510774710784910784a10794c117a4e117b4f127b"
    "51127c52137c54137d56147d57157e59157e5a167e5c167f"
    "5d177f5f187f601880621980641a80651a80671b80681c81"
    "6a1c816b1d816d1d816e1e81701f81721f81732081752181"
    "7621817822817922827b23827c23827e2482802582812581"
    "8326818426818627818827818928818b29818c29818e2a81"
    "902a81912b81932b80942c80962c80982d80992d809b2e7f"
    "9c2e7f9e2f7fa02f7fa1307ea3307ea5317ea6317da8327d"
    "aa337dab337cad347cae347bb0357bb2357bb3367ab5367a"
    "b73779b83779ba3878bc3978bd3977bf3a77c03a76c23b75"
    "c43c75c53c74c73d73c83e73ca3e72cc3f71cd4071cf4070"
    "d0416fd2426fd3436ed5446dd6456cd8456cd9466bdb476a"
    "dc4869de4968df4a68e04c67e24d66e34e65e44f64e55064"
    "e75263e85362e95462ea5661eb5760ec5860ed5a5fee5b5e"
    "ef5d5ef05f5ef1605df2625df2645cf3655cf4675cf4695c"
    "f56b5cf66c5cf66e5cf7705cf7725cf8745cf8765cf9785d"
    "f9795df97b5dfa7d5efa7f5efa815ffb835ffb8560fb8761"
    "fc8961fc8a62fc8c63fc8e64fc9065fd9266fd9467fd9668"
    "fd9869fd9a6afd9b6bfe9d6cfe9f6dfea16efea36ffea571"
    "fea772fea973feaa74feac76feae77feb078feb27afeb47b"
    "feb67cfeb77efeb97ffebb81febd82febf84fec185fec287"
    "fec488fec68afec88cfeca8dfecc8ffecd90fecf92fed194"
    "fed395fed597fed799fed89afdda9cfddc9efddea0fde0a1"
    "fde2a3fde3a5fde5a7fde7a9fde9aafdebacfcecaefceeb0"
    "fcf0b2fcf2b4fcf4b6fcf6b8fcf7b9fcf9bbfcfbbdfcfdbf"
)

MAGMA = bytes.fromhex("".join(_HEX))
assert len(MAGMA) == 768
