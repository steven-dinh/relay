# Relay benchmarks

## Results: fastest to slowest

All **seven case/topology selections** and **nine eligible adapters** are covered
below. Native State-steady C2S is the one unmeasured combination. These are the
latest completed valid runs per adapter and compatible group from the audited
September 7–11, 2026 collections: **76 selected runs**, plus 20 earlier runs
retained separately.

**Rank 1 has the lowest median.** Tables sort by the unrounded median; exact
ties share a rank. P95 is shown separately and can favor a different library.
Rank resets for each workload, Studio version, and broadcast mode. There is no
combined ranking across those groups. Small differences in a single local
session do not establish repeatable wins.

Each row is one session with 30 persistent windows. Workload rankings measure
**sender frame intervals**, in milliseconds. Only the round-trip probe measures
request/echo latency. The source beside each library identifies the measured
benchmark revision; for Relay, it also identifies the library implementation.

**† Call duration** is median / p95 in microseconds per public submit or broadcast.
It is diagnostic, excludes deferred transport and receiver work, and does not
determine rank. Expand a workload and its diagnostic tables to see every
available timing metric:

- **Submission:** first submission start to final return, including inter-frame time.
- **Completion:** first submission start to final expected receipt.
- **Drain:** final submission return to final expected receipt.
- **Wall:** first submission start to final receipt passing correctness checks.

Bandwidth, packet size, remote-call counts, and memory/GC were unavailable in
these runs; no values or rankings are inferred for them. All workload runs passed
their exact submission/delivery counts and correctness checks.

<details open>
<summary><strong>Tiny steady C2S</strong></summary>

1 client; 1 message/frame; 3,600 measured frames per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Relay `3030944` | 4.534 | 7.765 | 39.700 / 60.800 |
| 2 | Native RemoteEvent `3030944` | 4.543 | 7.690 | 21.300 / 33.400 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 526.014 / 628.524 | 528.719 / 627.651 | 1.841 / 4.987 | 528.734 / 628.521 |
| Native RemoteEvent | 542.929 / 591.481 | 542.923 / 592.729 | 0.000 / 3.103 | 543.038 / 592.736 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | NetRay-Compile `4ce556e` | 4.527 | 7.900 | 34.500 / 50.700 |
| 2 | Relay `4ce556e` | 4.528 | 8.042 | 51.800 / 80.400 |
| 3 | Satset `4ce556e` | 4.577 | 10.038 | 23.900 / 41.100 |
| 4 | ByteNet `4ce556e` | 4.581 | 9.934 | 19.900 / 31.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 541.769 / 609.565 | 546.264 / 609.908 | 1.483 / 4.973 | 546.288 / 609.931 |
| Relay | 540.122 / 688.382 | 541.837 / 688.497 | 0.333 / 4.828 | 541.856 / 688.514 |
| Satset | 623.779 / 737.220 | 624.423 / 737.725 | 1.716 / 6.939 | 624.443 / 737.749 |
| ByteNet | 616.820 / 700.064 | 620.827 / 701.937 | 2.509 / 4.831 | 620.846 / 703.066 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Zap `4ce556e` | 4.468 | 7.761 | 33.000 / 49.600 |
| 2 | Warp `4ce556e` | 4.497 | 7.884 | 14.400 / 21.700 |
| 3 | Blink `4ce556e` | 4.530 | 7.860 | 37.800 / 56.200 |
| 4 | QuickNet `4ce556e` | 4.564 | 9.498 | 21.100 / 32.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Zap | 531.402 / 645.780 | 531.473 / 645.404 | 0.359 / 2.590 | 531.894 / 645.780 |
| Warp | 539.021 / 623.148 | 542.053 / 621.125 | 1.789 / 5.162 | 542.070 / 623.149 |
| Blink | 546.423 / 630.832 | 547.637 / 627.139 | 2.999 / 4.869 | 547.656 / 630.828 |
| QuickNet | 556.532 / 982.286 | 557.915 / 983.027 | 0.819 / 3.383 | 558.202 / 983.050 |

</details>

</details>

<details>
<summary><strong>State steady C2S</strong></summary>

1 client; 1 message/frame; 3,600 measured frames per run. Native has no compatible measurement.

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Relay `4ce556e` | 4.467 | 7.601 | 55.850 / 84.800 |
| 2 | Satset `4ce556e` | 4.499 | 7.912 | 23.650 / 36.900 |
| 3 | NetRay-Compile `4ce556e` | 4.507 | 7.516 | 29.000 / 45.500 |
| 4 | ByteNet `4ce556e` | 4.567 | 8.022 | 19.900 / 29.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 522.640 / 629.700 | 524.827 / 631.713 | 0.874 / 4.249 | 524.851 / 631.734 |
| Satset | 536.619 / 632.671 | 536.858 / 632.454 | 1.053 / 5.384 | 537.163 / 632.668 |
| NetRay-Compile | 531.612 / 613.390 | 536.838 / 614.841 | 0.000 / 2.619 | 537.724 / 614.868 |
| ByteNet | 545.683 / 657.259 | 547.861 / 661.160 | 1.128 / 4.634 | 547.881 / 661.185 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Warp `4ce556e` | 4.466 | 7.793 | 14.500 / 21.900 |
| 2 | QuickNet `4ce556e` | 4.508 | 7.795 | 21.000 / 31.500 |
| 3 | Zap `4ce556e` | 4.526 | 7.886 | 34.200 / 51.500 |
| 4 | Blink `4ce556e` | 4.546 | 7.932 | 36.500 / 52.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Warp | 537.377 / 637.440 | 536.289 / 637.147 | 1.256 / 3.027 | 537.379 / 637.438 |
| QuickNet | 537.522 / 629.624 | 538.747 / 632.348 | 1.089 / 4.395 | 538.951 / 632.379 |
| Zap | 549.720 / 633.558 | 550.503 / 633.984 | 0.430 / 3.016 | 550.528 / 634.013 |
| Blink | 542.741 / 624.569 | 544.856 / 624.439 | 0.637 / 5.097 | 546.605 / 624.569 |

</details>

</details>

<details>
<summary><strong>State burst C2S</strong></summary>

1 client; 4 messages/frame; 300 measured frames and 1,200 calls per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Relay `3030944` | 4.542 | 7.892 | 14.000 / 47.100 |
| 2 | Native RemoteEvent `3030944` | 4.554 | 7.626 | 8.850 / 26.200 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 41.919 / 50.517 | 42.129 / 66.831 | 0.259 / 3.579 | 43.250 / 66.839 |
| Native RemoteEvent | 38.399 / 47.159 | 40.695 / 48.601 | 1.455 / 5.374 | 41.519 / 49.838 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | ByteNet `4ce556e` | 4.459 | 7.617 | 7.600 / 23.600 |
| 2 | NetRay-Compile `4ce556e` | 4.478 | 7.239 | 8.650 / 35.600 |
| 3 | Relay `4ce556e` | 4.516 | 7.730 | 15.750 / 51.900 |
| 4 | Satset `4ce556e` | 4.543 | 8.072 | 7.950 / 22.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| ByteNet | 38.543 / 49.615 | 38.805 / 54.370 | 0.117 / 5.005 | 39.469 / 54.377 |
| NetRay-Compile | 38.493 / 46.129 | 39.127 / 48.172 | 1.002 / 4.052 | 39.305 / 48.179 |
| Relay | 39.765 / 50.734 | 39.160 / 49.353 | 0.000 / 3.325 | 40.475 / 50.734 |
| Satset | 39.698 / 54.969 | 42.390 / 58.515 | 0.823 / 4.093 | 42.397 / 58.523 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Zap `4ce556e` | 4.420 | 7.757 | 10.200 / 33.500 |
| 2 | QuickNet `4ce556e` | 4.495 | 5.283 | 6.100 / 17.900 |
| 3 | Blink `4ce556e` | 4.556 | 8.242 | 9.500 / 34.400 |
| 4 | Warp `4ce556e` | 4.608 | 8.286 | 6.000 / 15.400 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Zap | 38.357 / 49.619 | 39.626 / 48.838 | 0.533 / 3.246 | 39.798 / 49.613 |
| QuickNet | 37.578 / 42.045 | 38.762 / 44.557 | 0.753 / 2.921 | 38.913 / 44.567 |
| Blink | 42.291 / 50.691 | 43.784 / 51.870 | 1.249 / 5.295 | 43.871 / 51.881 |
| Warp | 43.855 / 55.256 | 45.670 / 56.209 | 0.396 / 3.793 | 45.760 / 56.218 |

</details>

</details>

<details>
<summary><strong>State broadcast / 1 recipient</strong></summary>

1 broadcast/frame; 3,600 measured frames and 3,600 correct deliveries per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Relay `89b4d2f` | 4.544 | 7.822 | 37.400 / 57.600 |
| 2 | Native RemoteEvent `89b4d2f` | 4.575 | 7.824 | 19.600 / 30.300 |
| 3 | Satset `89b4d2f` | 4.577 | 7.692 | 15.400 / 23.800 |
| 4 | ByteNet `89b4d2f` | 4.592 | 7.863 | 13.800 / 19.100 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Relay | 532.380 / 616.741 | 537.865 / 625.565 | 7.445 / 10.499 | 537.882 / 625.589 |
| Native RemoteEvent | 535.036 / 611.920 | 541.997 / 616.625 | 5.190 / 10.097 | 542.022 / 616.647 |
| Satset | 525.350 / 587.511 | 535.736 / 592.222 | 8.304 / 13.316 | 535.752 / 592.231 |
| ByteNet | 552.125 / 627.779 | 561.210 / 637.748 | 6.745 / 10.828 | 561.229 / 637.756 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | NetRay-Compile `4ce556e` | 4.556 | 7.867 | 28.800 / 44.400 |
| 2 | ByteNet `4ce556e` | 4.557 | 7.772 | 17.400 / 25.500 |
| 3 | Satset `4ce556e` | 4.561 | 7.923 | 22.200 / 33.200 |
| 4 | Relay `4ce556e` | 4.579 | 7.805 | 43.400 / 64.500 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 553.121 / 629.099 | 562.449 / 638.246 | 8.448 / 11.626 | 562.479 / 638.275 |
| ByteNet | 521.041 / 599.662 | 529.613 / 607.074 | 8.069 / 10.865 | 529.634 / 607.087 |
| Satset | 537.664 / 613.312 | 546.421 / 618.463 | 8.134 / 11.324 | 546.443 / 618.472 |
| Relay | 535.304 / 683.689 | 540.999 / 690.255 | 8.144 / 12.218 | 541.011 / 690.269 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Blink `4ce556e` | 4.556 | 7.842 | 41.800 / 67.400 |
| 2 | Zap `4ce556e` | 4.556 | 7.753 | 37.300 / 58.200 |
| 3 | QuickNet `4ce556e` | 4.580 | 8.264 | 23.300 / 39.000 |
| 4 | Warp `4ce556e` | 4.581 | 7.853 | 19.700 / 28.900 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Blink | 541.193 / 628.693 | 547.518 / 635.955 | 5.661 / 11.378 | 547.543 / 635.979 |
| Zap | 527.271 / 608.130 | 536.355 / 614.230 | 5.838 / 9.519 | 536.378 / 614.257 |
| QuickNet | 553.689 / 649.788 | 564.231 / 653.328 | 9.078 / 13.518 | 564.259 / 653.345 |
| Warp | 541.273 / 637.183 | 547.366 / 644.098 | 5.296 / 8.946 | 547.381 / 644.130 |

</details>

</details>

<details>
<summary><strong>State broadcast / 4 recipients</strong></summary>

1 broadcast/frame; 3,600 measured frames and 14,400 correct deliveries per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Native RemoteEvent `89b4d2f` | 4.562 | 8.191 | 27.900 / 45.500 |
| 2 | ByteNet `89b4d2f` | 4.584 | 8.281 | 22.200 / 36.900 |
| 3 | Relay `89b4d2f` | 4.607 | 7.789 | 50.300 / 75.800 |
| 4 | Satset `89b4d2f` | 4.627 | 8.263 | 25.100 / 45.100 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Native RemoteEvent | 566.752 / 616.700 | 577.747 / 627.736 | 11.142 / 16.552 | 577.777 / 627.770 |
| ByteNet | 565.904 / 645.741 | 580.795 / 660.856 | 11.106 / 24.944 | 580.816 / 660.870 |
| Relay | 538.907 / 595.725 | 832.605 / 892.242 | 329.783 / 335.955 | 832.624 / 892.270 |
| Satset | 572.335 / 704.628 | 586.899 / 721.046 | 11.729 / 30.587 | 586.934 / 721.064 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | NetRay-Compile `96e8156` | 4.507 | 8.102 | 32.800 / 49.500 |
| 2 | Relay `96e8156` | 4.600 | 8.042 | 48.500 / 71.700 |
| 3 | ByteNet `96e8156` | 4.601 | 8.000 | 20.500 / 30.800 |
| 4 | Satset `96e8156` | 4.611 | 7.941 | 22.400 / 33.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 556.225 / 626.535 | 566.417 / 636.978 | 9.401 / 17.450 | 566.435 / 637.009 |
| Relay | 552.713 / 603.809 | 562.001 / 613.966 | 8.855 / 15.235 | 562.021 / 613.997 |
| ByteNet | 535.751 / 628.958 | 545.445 / 636.430 | 9.954 / 13.873 | 545.461 / 636.455 |
| Satset | 561.835 / 636.550 | 572.318 / 668.878 | 9.791 / 61.814 | 572.341 / 668.884 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Warp `4ce556e` | 4.190 | 7.762 | 23.700 / 33.900 |
| 2 | Blink `4ce556e` | 4.211 | 7.906 | 67.400 / 104.100 |
| 3 | Zap `4ce556e` | 4.561 | 8.093 | 69.700 / 103.800 |
| 4 | QuickNet `4ce556e` | 4.638 | 8.240 | 33.200 / 48.800 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Warp | 528.357 / 608.407 | 536.003 / 618.289 | 9.632 / 12.394 | 536.035 / 618.319 |
| Blink | 528.497 / 630.492 | 539.129 / 652.412 | 10.298 / 13.612 | 539.157 / 652.430 |
| Zap | 541.280 / 671.463 | 551.169 / 684.747 | 10.387 / 16.921 | 551.201 / 684.778 |
| QuickNet | 578.216 / 640.736 | 588.498 / 648.612 | 9.913 / 19.036 | 588.527 / 648.642 |

</details>

</details>

<details>
<summary><strong>State broadcast / 8 recipients</strong></summary>

1 broadcast/frame; 3,600 measured frames and 28,800 correct deliveries per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Native RemoteEvent `3030944` | 4.639 | 10.266 | 31.200 / 52.000 |
| 2 | ByteNet `89b4d2f` | 4.750 | 11.249 | 27.100 / 45.300 |
| 3 | Satset `89b4d2f` | 4.986 | 13.356 | 30.000 / 53.400 |
| 4 | Relay `3030944` | 5.092 | 16.380 | 57.900 / 112.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Native RemoteEvent | 619.200 / 784.168 | 634.654 / 1115.417 | 15.555 / 427.087 | 634.694 / 1115.449 |
| ByteNet | 655.815 / 785.525 | 670.773 / 800.507 | 14.693 / 29.334 | 670.894 / 800.563 |
| Satset | 715.610 / 910.524 | 731.765 / 993.784 | 17.475 / 52.981 | 731.793 / 993.798 |
| Relay | 790.812 / 968.505 | 811.176 / 998.909 | 19.613 / 31.407 | 811.198 / 998.941 |

</details>

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | NetRay-Compile `96e8156` | 4.475 | 9.352 | 42.100 / 78.000 |
| 2 | Relay `96e8156` | 4.477 | 12.012 | 68.200 / 130.200 |
| 3 | Satset `96e8156` | 4.601 | 13.727 | 29.100 / 61.400 |
| 4 | ByteNet `96e8156` | 4.627 | 13.788 | 26.200 / 54.700 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| NetRay-Compile | 596.720 / 673.044 | 610.041 / 686.914 | 13.578 / 21.600 | 610.082 / 686.949 |
| Relay | 670.355 / 808.411 | 698.689 / 818.906 | 16.154 / 31.654 | 698.707 / 818.936 |
| Satset | 686.292 / 929.563 | 705.899 / 947.947 | 17.205 / 49.201 | 705.942 / 947.961 |
| ByteNet | 680.330 / 846.559 | 694.044 / 911.434 | 15.415 / 31.668 | 694.073 / 911.461 |

</details>

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | Frame median ms | Frame p95 ms | Call median / p95 µs † |
| ---: | --- | ---: | ---: | ---: |
| 1 | Warp `4ce556e` | 4.646 | 10.004 | 34.300 / 52.500 |
| 2 | Blink `4ce556e` | 4.687 | 9.848 | 106.300 / 161.500 |
| 3 | QuickNet `4ce556e` | 4.737 | 12.457 | 46.000 / 73.400 |
| 4 | Zap `4ce556e` | 4.877 | 14.211 | 112.600 / 197.000 |

<details>
<summary>Other timing diagnostics (median / p95 ms; same row order)</summary>

| Library | Submission | Completion | Drain | Wall |
| --- | ---: | ---: | ---: | ---: |
| Warp | 627.447 / 738.501 | 641.491 / 754.505 | 14.308 / 25.544 | 641.524 / 754.534 |
| Blink | 627.118 / 737.135 | 639.643 / 754.520 | 13.179 / 31.709 | 639.670 / 754.534 |
| QuickNet | 686.544 / 835.823 | 698.914 / 962.076 | 18.154 / 26.236 | 698.930 / 963.005 |
| Zap | 743.194 / 938.744 | 759.757 / 958.500 | 16.118 / 54.602 | 759.791 / 958.515 |

</details>

</details>

<details>
<summary><strong>Tiny round trip</strong></summary>

1 client; one request in flight; 3,600 measured request/echo round trips per run.

### Studio 0.738.0.7381393 / NativeBroadcast

| Rank | Library · source | RTT median ms | RTT p95 ms |
| ---: | --- | ---: | ---: |
| 1 | Native RemoteEvent `3030944` | 7.935 | 11.095 |
| 2 | Relay `3030944` | 7.976 | 9.174 |
| 3 | Satset `89b4d2f` | 10.973 | 15.925 |
| 4 | ByteNet `89b4d2f` | 11.079 | 12.697 |

### Studio 0.737.0.7371584 / NativeBroadcast

| Rank | Library · source | RTT median ms | RTT p95 ms |
| ---: | --- | ---: | ---: |
| 1 | ByteNet `4ce556e` | 7.986 | 9.424 |
| 2 | Satset `4ce556e` | 8.034 | 12.590 |
| 3 | Relay `4ce556e` | 11.202 | 13.023 |
| 4 | NetRay-Compile `4ce556e` | 11.562 | 13.255 |

### Studio 0.737.0.7371584 / AdapterFanOut

| Rank | Library · source | RTT median ms | RTT p95 ms |
| ---: | --- | ---: | ---: |
| 1 | Warp `4ce556e` | 7.955 | 12.344 |
| 2 | QuickNet `4ce556e` | 11.302 | 12.926 |
| 3 | Blink `4ce556e` | 11.491 | 12.925 |
| 4 | Zap `4ce556e` | 11.849 | 12.876 |

</details>

<details>
<summary>Earlier observations from these collections (20 runs; unranked)</summary>

These remain individual runs. They were superseded by collection time, not by faster results. All use NativeBroadcast; dates are UTC.

| Case | Library · source | Studio | Finished UTC | Median / p95 ms | Run ID |
| --- | --- | --- | --- | ---: | --- |
| State broadcast / 4 recipients | Relay `4ce556e` | 0.737.0.7371584 | 2026-09-07T06:51:06 | 4.759 / 12.207 | `efd23780-78a9-4612-b778-73d03f024da4` |
| State broadcast / 8 recipients | Relay `4ce556e` | 0.737.0.7371584 | 2026-09-07T06:53:55 | 6.334 / 14.970 | `65c6b855-e103-4070-8fa3-bc559eac2004` |
| State broadcast / 4 recipients | ByteNet `4ce556e` | 0.737.0.7371584 | 2026-09-07T07:41:03 | 4.589 / 8.042 | `c138991d-adba-45dc-9e7c-ae6bce525c65` |
| State broadcast / 4 recipients | Satset `4ce556e` | 0.737.0.7371584 | 2026-09-07T07:42:28 | 4.196 / 7.955 | `89e96915-5e02-483d-9eaf-1159365576a3` |
| State broadcast / 4 recipients | NetRay-Compile `4ce556e` | 0.737.0.7371584 | 2026-09-07T23:18:09 | 4.581 / 7.817 | `ffec3402-6635-4646-b154-07ada8524a35` |
| State broadcast / 8 recipients | ByteNet `4ce556e` | 0.737.0.7371584 | 2026-09-07T23:22:09 | 4.673 / 9.817 | `cc07e24d-3e48-4743-91e7-bbc16f50a3cc` |
| State broadcast / 8 recipients | Satset `4ce556e` | 0.737.0.7371584 | 2026-09-07T23:24:14 | 5.020 / 13.122 | `68c36d47-ee17-496e-88cd-1b04e9331404` |
| State broadcast / 8 recipients | NetRay-Compile `4ce556e` | 0.737.0.7371584 | 2026-09-07T23:32:21 | 4.883 / 14.638 | `5c0ecc23-8d95-4436-be0a-ecc65b5459a6` |
| State broadcast / 4 recipients | Relay `96e8156` | 0.737.0.7371584 | 2026-09-09T03:03:21 | 4.576 / 8.262 | `44195642-eac7-4b8d-adf7-c8abebfce003` |
| State broadcast / 4 recipients | ByteNet `96e8156` | 0.737.0.7371584 | 2026-09-09T03:04:53 | 4.641 / 8.072 | `26b0859a-41ee-4031-8bfd-b4fa16be601e` |
| State broadcast / 4 recipients | Satset `96e8156` | 0.737.0.7371584 | 2026-09-09T03:06:19 | 4.619 / 8.184 | `ea232dfc-beba-452e-b298-4d2d683b44c9` |
| State broadcast / 4 recipients | NetRay-Compile `96e8156` | 0.737.0.7371584 | 2026-09-09T03:07:48 | 4.601 / 8.081 | `2501e0dc-8f7c-4245-a244-2a48277dc638` |
| State broadcast / 8 recipients | Relay `96e8156` | 0.737.0.7371584 | 2026-09-09T03:09:46 | 4.670 / 10.448 | `d1d471be-30e2-423f-a97b-1ebc85cce59d` |
| State broadcast / 8 recipients | ByteNet `96e8156` | 0.737.0.7371584 | 2026-09-09T03:11:43 | 4.587 / 9.439 | `efe9701b-953d-4ef0-9c87-1ed86df72a0c` |
| State broadcast / 8 recipients | Satset `96e8156` | 0.737.0.7371584 | 2026-09-09T03:13:39 | 4.640 / 9.815 | `7244c72e-4b37-40e4-bcae-759cd44ac733` |
| State broadcast / 8 recipients | NetRay-Compile `96e8156` | 0.737.0.7371584 | 2026-09-09T03:15:36 | 4.733 / 11.007 | `bdd68e43-0122-49a7-b5ce-4e8ebb436ac8` |
| Tiny round trip | Native RemoteEvent `89b4d2f` | 0.738.0.7381393 | 2026-09-10T21:54:57 | 7.966 / 10.380 | `4bfd0e66-6b3c-46f8-af32-539fbca2ea52` |
| Tiny round trip | Relay `89b4d2f` | 0.738.0.7381393 | 2026-09-10T21:56:37 | 8.094 / 12.363 | `2ebe6fc9-2487-4b25-a5e8-3d81f74b14de` |
| State broadcast / 8 recipients | Native RemoteEvent `89b4d2f` | 0.738.0.7381393 | 2026-09-10T22:15:39 | 4.820 / 11.858 | `9757aef2-bb46-46c3-86d7-6434c5dfecfe` |
| State broadcast / 8 recipients | Relay `89b4d2f` | 0.738.0.7381393 | 2026-09-10T22:17:42 | 4.980 / 11.757 | `39fb7589-66f0-4616-b89e-ec1a19d53a3d` |

</details>

<details>
<summary>Versions, source revisions, and collection record</summary>

| Adapter | Measured library version |
| --- | --- |
| Native RemoteEvent | Studio version in each table |
| Relay | 0.1.0, with the exact revision shown per row |
| ByteNet | v0.4.3 |
| Satset | v0.4.2 |
| NetRay-Compile | v0.1.1-cli.1 |
| Blink | v0.18.8 |
| QuickNet | v0.3.4-beta |
| Warp | 1.0.14 |
| Zap | v0.6.29 |

| Source revision | Collection date (UTC) | Valid runs |
| --- | --- | ---: |
| `4ce556e` | September 7 | 56 |
| `96e8156` | September 9 | 16 |
| `89b4d2f` | September 10 | 16 |
| `3030944` | September 11 | 8 |

All 96 artifacts passed hash checks, Result V2 validation, and the strict
comparison reporter. Selection uses each ledger's completion timestamp, never
the fastest repeat. Compatible groups also require matching profile, contract,
measurement fingerprint, host, and topology; all use `EquivalentSemantics`
and `PersistentSession`. Native broadcast and adapter fan-out remain separate,
including for C2S and round-trip cases.

The September 7 collection had a roughly 15-hour pause and one numerical-summary
rejection followed by an unchanged-source retry. September 9 used forward and
reverse collection orders. September 11 initially rejected a dirty checkout
before measurement, then restarted in a clean checkout. No timing-based retries
were used. Machine identity does not prove stable load or temperature; 30 windows
in one process are correlated observations. These results do not establish
production internet performance.

Raw results and logs remain private and ignored. The local inputs are indexed by
these files under `benchmarks/results/local/`:

- `audit-clock-admission-2026-09-07.json`
- `broadcast-repeat-2026-09-08.audit.json` (September 9 UTC)
- `current-relay-2026-09-10.audit.json`
- `relay-3030944-vs-libraries-2026-09-11.audit.json`

</details>

## Run the current benchmarks

Use `PersistentBenchmark`: one fresh Studio multiplayer session per
adapter/case/topology, with 30 windows and Result V2 (`event-session-v1`).
Run from the repository root on Windows with the tools in
[`rokit.toml`](../rokit.toml), a clean Git checkout, and no existing Studio
processes. Keep the argument order shown and run selections serially.

```powershell
$studio = 'C:/path/to/RobloxStudioBeta.exe'
lune run benchmarks/host/run-event-v1.luau --studio $studio --mode PersistentBenchmark --case state-burst-c2s --recipients 1 --adapter relay-reliable
```

| Case | `--recipients` | Load |
| --- | --- | --- |
| `tiny-steady-c2s` | 1 | 1 Tiny message/frame |
| `state-steady-c2s` | 1 | 1 State message/frame |
| `state-burst-c2s` | 1 | 4 State messages/frame |
| `state-broadcast-s2c` | 1, 4, or 8 | 1 State broadcast/frame |
| `tiny-round-trip` | 1 | Sequential Tiny request/echo |

Tiny contains `sequence: u32` and `enabled: boolean`. State contains
`sequence: u32`, `entityId: u16`, `position: Vector3F32`, `yaw: f32`, and
`health: u8`. Workloads advance on `PostSimulation`; 60 FPS is a target,
so offered messages per second vary with actual frame rate. Avatars are disabled.

Adapter IDs: `native-reliable` (default), `relay-reliable`, `quicknet`,
`bytenet`, `satset`, `warp`, `blink`, `zap`, and `netray-compile`.
Suphi-Packet is excluded because its intentional sender buffering cannot be
proven to satisfy the one-added-frame limit. For external adapters, first run:

```powershell
lune run scripts/acquire-benchmark-libraries.luau --all
lune run scripts/generate-benchmark-adapters.luau --all
```

Both commands support `--verify`. See the [adapter guide](adapters/README.md)
for qualification and [the lock file](libraries.lock.json) for versions and
licenses. Never edit or commit downloaded libraries, generated code, or raw
local result artifacts.

Results are written to `benchmarks/results/local/<launch-id>.result-v2.json`
after source/artifact checks and confirmed Studio exit. Only `Valid` results
make the host command succeed. If it reports `HOST_E_CHILD_LIVE`, confirm the
Studio processes have exited before another run. Keep authenticated logs private.

```powershell
lune run benchmarks/reporting/compare-results.luau --result "<first.result-v2.json>" --result "<second.result-v2.json>"
```

## Measurement rules

- Prove correctness separately from timing. Fresh deterministic inputs must
  survive unchanged; missing, duplicate, stale, misordered, or corrupted delivery
  invalidates a run. Preserve receiver-before-sender ordering, continuous
  observation, and verified cleanup.
- Keep setup, dependency loading, readiness, warmup, both 60-frame quiet windows,
  and result extraction outside timing. No runner control traffic is allowed
  during measured frames.
- Workloads rank only by `frameTime`; the separate probe ranks by
  `roundTripLatency`. Call duration, shared-clock completion/drain/wall duration,
  and engine-wide send rate are diagnostics. Local durations use `os.clock()`;
  approximate shared-clock durations cannot decide rankings. The 3 ms startup
  clock allowance is not an accuracy guarantee.
- Compare matching case/topology, lane, broadcast mode, profile/isolation,
  contract, measurement fingerprint, Studio, and host metadata. Keep every run
  separate; never pool incompatible samples, repair invalid evidence, or relabel
  old results. Record collection order, failures, retries, and machine conditions.
- Documentation changes need evidence validation, not fresh Studio timing runs.
  Use focused checks during development and a full matrix only after the measured
  setup is frozen. Shared measurement changes require a new cohort; adapter
  changes require new evidence for that adapter. Correctness is not a decoder
  security audit.

The [workload contract](contracts/event-v1.luau),
[session profile](contracts/internal/PersistentSessionProfile.luau), and
[host](host/HostRuntime.luau) define the detailed boundaries. Relay's
[binding](adapters/relay-reliable/init.luau) uses the public API with production
validation and admission limits enabled. Portable correctness checks run with
`lune run scripts/verify-foundation.luau` without launching Studio.
