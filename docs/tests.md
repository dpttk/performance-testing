# Как работают тесты

Этот документ описывает каждый этап пайплайна `sudo ./scripts/run.sh` в human-readable формате.
Псевдокод ниже отражает реальную логику скриптов, но без shell-специфики.

## Общая схема

```
verify host
    -> generate profile (scan mode)
    -> functional check + enforcement overhead
    -> performance benchmarks (baselines + hardened latency)
    -> aggregate report
    -> publish results/latest/
```

Главный объект сравнения: **ваш runtime в enforced-режиме** (профили seccomp + AppArmor + capabilities уже применены).
Бейзлайны: `stock`, `gvisor`, `docker`.

---

## 1. Verify (`scripts/verify.sh`)

**Цель:** убедиться, что хост готов к прогону, без запуска полного benchmark.

**Проверяется:**

- бинарники `runc-stock`, `runc-hardened`, `runsc`
- containerd socket и namespace
- Docker engine
- инструменты: `iperf3`, `redis-benchmark`, scan toolchain
- smoke-test: короткий контейнер `/bin/true` для `stock`, `gvisor`, `docker`

**Псевдокод:**

```
for each prerequisite:
    if missing: FAIL

for runtime in [stock, gvisor, docker]:
  run container(busybox, command=/bin/true)
  if failed: FAIL
```

---

## 2. Profile generation (`profile_generate_bundle`)

**Цель:** получить профили безопасности из synthetic workload и подготовить два bundle:
`raw` (без профилей) и `enforced` (с профилями).

**Контейнер / workload:**

- image: `busybox:latest` (по умолчанию)
- synthetic command: 500 чтений `/etc/passwd`, вывод `RESULT=<count>`

**Псевдокод:**

```
export rootfs from busybox image
write OCI config with uid/gid=65532 and synthetic workload
snapshot config as config.raw.json

start_timer()
run runc-hardened --security-scan on workload
  collect syscalls -> seccomp.json
  collect caps -> capable log
  collect file access -> apparmor.profile
stop_timer() -> scan_ms

create bundles:
  raw/      uses config.raw.json
  enforced/ uses post-scan config + generated/*
```

**Артефакты:**

- `bundles/scanned/synthetic/raw/`
- `bundles/scanned/synthetic/enforced/`
- `bundles/scanned/synthetic/profile-summary.json`

---

## 3. Functional check + enforcement overhead (`profile_measure_enforcement`)

**Цель:** доказать, что enforced-профиль не ломает workload, и измерить overhead политик.

### 3.1 Functional check

```
raw_output   = run(raw bundle, synthetic workload)
enforced_out = run(enforced bundle, synthetic workload)

if raw_output != enforced_out:
    FAIL pipeline
```

Ожидаемый результат: `RESULT=500` в обоих вариантах.

### 3.2 Enforcement overhead

```
for variant in [raw, enforced]:
    warmup WARMUP times
    repeat REPS times:
        measure wall time of full bundle run

overhead_pct = (median_enforced / median_raw - 1) * 100
```

**Важно:** overhead считается **валидным только если functional check прошёл**.

**Артефакт:** `enforcement.json`

---

## 4. Startup latency (`bench_latency`)

**Цель:** время запуска и завершения короткого контейнера.

**Контейнер:** `busybox:latest`, команда `/bin/true`

**Рантаймы:**

- `stock` (ctr + runc-stock)
- `gvisor` (docker + runsc)
- `docker` (docker default)
- `hardened_enforced` (runc-hardened bundle с `/bin/true` и применёнными профилями)

**Псевдокод:**

```
for runtime in active_runtimes:
  warmup WARMUP launches
  samples = []
  repeat REPS:
      t0 = now()
      run_and_exit(runtime, busybox, /bin/true)
      samples.append(now() - t0)
  stats = median/p95/p99/stddev(samples)
```

**Артефакт:** `latency.json`

---

## 5. CPU + memory throughput (`bench_cpu_mem`)

**Цель:** вычислительная и memory throughput внутри контейнера.

**Контейнер:** `severalnines/sysbench:latest`

**Рантаймы:** только `stock`, `gvisor`, `docker`

> `hardened_enforced` здесь не участвует: его bundle rootfs — busybox, в нём нет sysbench.
> Для enforced-режима основной workload-метрикой используется блок enforcement overhead (шаг 3).

**Псевдокод:**

```
for runtime in [stock, gvisor, docker]:
  repeat REPS:
    out = run(runtime, sysbench_image, "sysbench cpu ...")
    parse events/sec -> cpu_samples

  repeat REPS:
    out = run(runtime, sysbench_image, "sysbench memory ...")
    parse MiB/s -> mem_samples
```

**Артефакты:** `sysbench-cpu.json`, `sysbench-mem.json`

---

## 6. Network throughput (`bench_network`)

**Цель:** loopback network throughput внутри одного контейнера.

**Контейнер:** `networkstatic/iperf3:latest`

**Рантаймы:** `stock`, `gvisor`, `docker`

**Псевдокод:**

```
for runtime in [stock, gvisor, docker]:
  repeat REPS:
    start iperf3 server in container
  run iperf3 client to 127.0.0.1 for IPERF_DURATION seconds
  parse receiver Gbit/s
```

**Артефакт:** `network.json`

---

## 7. Application workload: Redis (`bench_app_redis`)

**Цель:** syscall-heavy app workload (server + client в одном контейнере).

**Контейнер:** `redis:7-alpine`

**Рантаймы:** `stock`, `gvisor`, `docker`

**Псевдокод:**

```
for runtime in [stock, gvisor, docker]:
  repeat REPS:
    start redis-server in container
    run redis-benchmark SET/GET (loopback)
    parse req/s for SET and GET
```

**Артефакты:** `redis-set.json`, `redis-get.json`

---

## 8. Report aggregation (`scripts/report.py`)

**Цель:** собрать JSON-метрики в читаемый отчёт.

**Вход:** все JSON в `results/<campaign>/`

**Выход:**

- `report.md` — таблицы median/p95/stddev и сравнение с `stock`
- `report.csv` — плоская таблица для анализа
- `plots/*.png` — bar charts (если доступен matplotlib)

**Псевдокод:**

```
load metric json files if present
build markdown tables per metric
add enforcement-overhead section from enforcement.json
write report.md + report.csv + plots
```

---

## Что должно быть в `results/latest/`

После успешного `run.sh` в `results/latest/` должны быть:

| Файл | Содержание |
|------|------------|
| `host-metadata.txt` | параметры хоста и версии runtime |
| `enforcement.json` | scan cost, functional check, raw vs enforced overhead |
| `latency.json` | startup latency (включая hardened_enforced) |
| `sysbench-cpu.json` | CPU throughput |
| `sysbench-mem.json` | memory throughput |
| `network.json` | iperf3 loopback |
| `redis-set.json` / `redis-get.json` | Redis throughput |
| `active-runtimes.txt` | список реально запущенных runtime |
| `report.md` / `report.csv` | агрегированный отчёт |
| `plots/` | графики (опционально) |

---

## Известные ограничения методологии

1. **Launcher asymmetry:** `stock` через containerd/ctr, `gvisor` и `docker` через Docker CLI.
2. **Latency для `hardened_enforced`:** запускается как `runc-hardened run --bundle` (прямой OCI bundle), без containerd/Docker shim. Поэтому startup latency для enforced **не сопоставима 1:1** с `stock/gvisor/docker` на уровне launcher overhead. Для сравнения enforced-cost на том же workload используйте `enforcement.json` (raw vs enforced bundle).
3. **Enforced bundle rootfs:** только busybox; sysbench/iperf3/redis для enforced сравниваются косвенно через enforcement overhead на synthetic workload.
4. **Synthetic profile:** профиль учится на `cat /etc/passwd` loop, не на полном приложении.
5. **CPU governor:** на некоторых VM cpufreq недоступен, pinning пропускается.
