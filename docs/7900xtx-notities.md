# RX 7900 XTX in Strata: wat upstream weet

Samengevat uit upstream op commit `296b59d2` (engine 0.1.44.1, 14 okt 2026). Paden zijn relatief aan de Strata-repo.
Getallen zijn van anderen, op hun machines; ze zijn het startpunt, `xtx-bench` op jouw machine is het oordeel.

## Gemeten op gfx1100

| bron | machine | wat | cijfers |
| --- | --- | --- | --- |
| `bench/results/2026-10-06-community-rx-7900-xtx` | XTX, 7950X3D, 192 GB, Windows, 0.1.40 | IQ3_S, 262K, kv int8, `--prefill auto:32768`, tabel 100500 | decode 77-80 tok/s; 38K-prompt 1.612 tok/s; RAM 69-70 GiB |
| `bench/results/2026-10-03-community-rx7900xtx-rocm102-nightly` | XTX, 7900X, 96 GB DDR5, Fedora | ROCm 7.1.1 vs 10.2-nightly, IQ3_S | warme decode 80,4 → **88,4 tok/s (+10%)** met de nieuwere ROCm |
| `bench/results/2026-10-04-community-rx7900xtx-hipblaslt-100500` | idem | 128K-prompt met/zonder passende hipBLASLt-tabel | **926 → 1.687 tok/s** (+82%); decode gelijk |
| `docs/AMD_HIP.md` (#1389) | XTX, 50 GB RAM | lange prompts | `PF_FUSED/PF_GEMM/SWITCH_MIN_T` 925 → 1.092; `--resident-experts` 1.092 → 2.503; `--prefill auto:32768` +23% bij 74K |
| `bench/results/2026-10-09-community-4x-rx-7900-xt` | 4x 7900 XT, 0.1.41 | opt-ins aan/uit | prompt 4K 756 → **2.052**, 32K 1.722 → 3.804, 128K 2.433 → 4.307; decode gelijk |
| `docs/AMD_HIP.md` (gfx1100-100401) | XTX, 9800X3D, ROCm 10.0 | 43-rijentabel met small-T-rijen | 3K-prompt 711 → 938 tok/s (+32%) |
| `docs/AMD_HIP_PERFORMANCE.md` | XTX, 7950X3D, 64 GB, ROCm 7.1 | HIP MMQ + tabel + staging | prompt 1,8-2,0x t.o.v. de oude HIP-runtime |
| `bench/results/2026-10-07-community-xtx-6800xt-1m-helper` | XTX + 6800 XT, Xeon, 121 GB | UD-Q4_K_XL, 1M context, research-build | ~97 tok/s coding-decode (spec 8, 15 workers, lag 2) |

## Wat daaruit volgt voor jouw opstelling

- **Model.** Met ~96 GB in de LXC past IQ3_S ruim (69-70 GiB gemeten bij 262K + 8 GiB gesprekscache) en is op de XTX
  het best gemeten. Meer kwaliteit: Unsloth `UD-IQ4_XS` (~72 GB) of `UD-Q4_K_XL` (~88 GB, top-token 93,1% vs 87,7%
  voor IQ3_S; op een R9700 63/87 tok/s tegen 75/95 voor IQ3_S). Q4_K_XL wil een LXC van ≥ 104 GB.
- **hipBLASLt-tabel = grootste losse hefboom voor prompts.** De engine gebruikt een tabel alleen bij exact passende
  arch + versie; anders plain hipBLAS (tot 45% trager). Upstream levert gfx1100-tabellen voor 1.1.0, 1.2.0, 1.2.2,
  1.4.1 en 1.5.0; alleen de 1.4.1-tabel heeft de small-T-expertrijen. `xtx-tune-hipblaslt` maakt er een voor jouw
  exacte versie met de unie van alle geometrieën plus T=16384/32768 (ons profiel leest chunks tot 32768).
- **ROCm-versie.** Setup installeert de geteste TheRock-wheels (7.10.0a20251120) in `.venv`. De 10.2-nightly gaf op
  een XTX +10% decode. Proberen kan via `ROCM_VERSION`/`ROCM_INDEX` in xtx.conf (setup's `STRATA_ROCM_VERSION` /
  `STRATA_ROCM_INDEX`), daarna `xtx-update --force` en `xtx-tune-hipblaslt`; `xtx-update --rollback` als het slechter is.
- **Headless.** Geen desktop op de kaart, dus de VRAM-reserve kan omlaag (512 MiB); elke 1,9 MiB is één expert-slot meer.
  De `3072`-adviezen in upstream gelden voor een kaart die ook een desktop aanstuurt.
- **LXC-geheugen.** Proxmox-LXC: de engine ziet de limiet van de container niet in cgroup (die zit op de parent), en
  lxcfs' `MemAvailable` klopte daar niet (25 GiB gemeld, 1 GiB echt). Vandaar `--memory-limit-mib` (docs/DETAILS.md,
  "The RAM figure"). In systemd nooit `MemoryHigh` (telt de page cache; een 16K-prompt hing 8 min in `pread`).
- **memlock.** De engine page-lockt het expert-arena; `lxc.prlimit.memlock: unlimited` + `LimitMEMLOCK=infinity`.
- **Huge pages.** De engine vraagt eerst hugetlb-2M-pagina's, anders THP (madvise). Met `vm.nr_hugepages` op de host
  (bv. ~24.000 voor ~47 GiB experts) krijgt het arena echte 2M-pagina's (minder TLB-missers bij de CPU-experts). Die
  pagina's zijn dan permanent weg uit de host-RAM; ongemeten winst. Alleen proberen als de host RAM over heeft.
- **Opslag.** De 28,8 GB n-gramtabel wordt per token willekeurig gelezen (`--ple-io direct`, O_DIRECT). Op ZFS/Ceph
  kan dat traag zijn; `--ple-io ram` kost ~29 GB RAM extra. `xtx-check` meldt het bestandssysteem.

## Bekende AMD-problemen en workarounds (upstream, docs/AMD_HIP.md)

- `verify: timed out at layer N` / "no progress for 60 s": vaak KFD-queue-suspensie terwijl de kernel gepind
  host-geheugen terugwint. Workarounds in de `env` van het run-config: `HSA_USERPTR_FOR_PAGED_MEM=0` (#750) of
  `GPU_PINNED_MIN_XFER_SIZE=1048576` (#920, met `--mmap-experts`). Eén tegelijk proberen.
- Lange prompts: zoek na de eerste vraag de regel `FileExpertSource: N of M of the prompt path's lendable slots keep
  their experts in RAM too`. N < M → `RESIDENT_HEADROOM_GIB` in xtx.conf iets omlaag (standaard 4); swapt de machine
  dan, weer omhoog. Na een ROCm-update opnieuw kijken.
- Ongeveer 1 op 10 starts geeft op HIP bij greedy een andere token ergens in het antwoord; upstream weet niet waarom.
- `STRATA_SH_STREAM` (shared expert op een tweede stream) is uit op HIP: platformafhankelijk (+5-13% op 2x 6900 XT
  Linux, -12-22% op een 6800 Windows). Zit in `xtx-decode-exp` om te meten.
- `STRATA_SELECT_WMMA` werkt alleen op gfx12; op gfx1100 doet hij niets (daarom niet in onze profielen).
