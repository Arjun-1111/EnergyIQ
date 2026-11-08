# IoT Telemetry Architecture & Time-Series Guide

[![Database](https://img.shields.io/badge/Database-TimescaleDB%20%7C%20PostgreSQL-336791?style=flat-square&logo=postgresql&logoColor=white)](#part-i-timescaledb-deep-dive)
[![Protocol](https://img.shields.io/badge/Protocol-MQTT%20v3.1.1%20%2F%20v5.0-660066?style=flat-square&logo=mqtt&logoColor=white)](#part-ii-mqtt-protocol-architecture)
[![License](https://img.shields.io/badge/Documentation-Technical%20Reference-brightgreen?style=flat-square)](#)

A comprehensive architectural reference detailing high-throughput time-series ingestion using **TimescaleDB** alongside lightweight telemetry streaming via **MQTT**.

---

## Table of Contents

- [Part I: TimescaleDB Deep Dive](#part-i-timescaledb-deep-dive)
    - [1. Hypertables & Chunking Mechanics](#1-hypertables--chunking-mechanics)
    - [2. Primary Key & Time Column Constraint Rule](#2-primary-key--time-column-constraint-rule)
    - [3. Index Optimization: Why Order Time by DESC?](#3-index-optimization-why-order-time-by-desc)
    - [4. Continuous Aggregates vs. Materialized Views](#4-continuous-aggregates-vs-materialized-views)
    - [5. Continuous Aggregate Refresh Policies](#5-continuous-aggregate-refresh-policies)
- [Part II: MQTT Protocol Architecture](#part-ii-mqtt-protocol-architecture)
    - [1. Publish/Subscribe (Pub/Sub) Model](#1-publishsubscribe-pubsub-model)
    - [2. Topic Hierarchies & Wildcards](#2-topic-hierarchies--wildcards)
    - [3. Quality of Service (QoS) Levels](#3-quality-of-service-qos-levels)
    - [4. Architectural Comparison: MQTT vs. HTTP](#4-architectural-comparison-mqtt-vs-http)
    - [5. Industry Use Cases](#5-industry-use-cases)

---

# Part I: TimescaleDB Deep Dive

## 1. Hypertables & Chunking Mechanics

A **Hypertable** is an abstraction layer built on top of standard PostgreSQL tables. To application runtimes and ORMs, it behaves like a standard SQL table supporting full `SELECT`, `INSERT`, `UPDATE`, and `JOIN` operations.

Under the hood, TimescaleDB automatically partitions this single relational interface into smaller, physical tables called **chunks**.

```text
+-----------------------------------------------------------+
|               energy_readings (Hypertable)                |  <-- Application Interface
+-----------------------------------------------------------+
                              |
     +------------------------+------------------------+
     |                                                 |
     v                                                 v
+-----------------------------+       +-----------------------------+
| Chunk 1: [Nov 01 -> Nov 02] |       | Chunk 2: [Nov 02 -> Nov 03] |
+-----------------------------+       +-----------------------------+
```

### Standard Tables vs. Hypertables

| Attribute | Standard PostgreSQL Table | TimescaleDB Hypertable |
| :--- | :--- | :--- |
| **Data Structure** | Monolithic heap table | Sliced into discrete time/space chunks |
| **Index Footprint** | B-Trees grow beyond RAM; forces constant disk swapping | Indexes remain pinned inside RAM per active chunk |
| **Write Performance** | Ingestion throughput plunges steeply as row counts scale | Continuous, flat-line ingestion performance |
| **Data Lifecycle** | Costly vacuuming and delete operations | Instant zero-cost chunk drops via metadata cleanup |

### What Does "1-Day Chunks" Mean?

Each chunk covers an immutable time window of exactly 24 hours:

* All telemetry with timestamps in `[2026-05-01 00:00:00, 2026-05-01 23:59:59]` maps to **Chunk A**.
* At midnight, incoming rows automatically write into a newly provisioned **Chunk B**.
* **Chunk Exclusion (Pruning):** When executing:
  ```sql
  SELECT * FROM energy_readings
  WHERE time BETWEEN '2026-05-01 02:00:00' AND '2026-05-01 04:00:00';
  ```
  The query planner examines table partition bounds, hits only **Chunk A**, and completely bypasses all other physical tables.

---

## 2. Primary Key & Time Column Constraint Rule

> **The Invariant Rule:** Any `PRIMARY KEY` or `UNIQUE` constraint declared on a hypertable **must include the partition time column**.

### The Filing Cabinet Analogy

Imagine a physical storage room where every day has its own dedicated filing cabinet:
* **Cabinet 1:** Monday
* **Cabinet 2:** Tuesday
* **Cabinet 3:** Wednesday

A clerk arrives on Wednesday holding an incoming reading for `device_id = 99`.

#### Scenario A: Primary Key is `(device_id)` (No time column)
* The database engine must enforce global uniqueness across history.
* Before filing the paper into Wednesday's drawer, the worker must halt operations, acquire locks, and inspect Monday, Tuesday, and all prior drawers.
* **Result:** Total lock contention and I/O degradation at scale.

#### Scenario B: Primary Key is `(time, device_id)` (Includes time)
* The engine only needs to guarantee uniqueness for that specific point in time on Wednesday.
* The worker walks directly to Wednesday's cabinet, checks only that day's files, writes the record, and moves on without locking historical partitions.
* **Result:** Uniqueness checks stay strictly local to memory-resident chunks.

---

## 3. Index Optimization: Why Order Time by DESC?

Standard B-Tree indexes default to ascending order (`ASC`):
$$\text{01:00} \longrightarrow \text{02:00} \longrightarrow \text{03:00} \longrightarrow \dots \longrightarrow \text{23:00}$$

### Inverted Dashboard Query Patterns

IoT, SCADA, and telemetry dashboards prioritize real-time statuses over historical cold data:

```sql
SELECT * FROM energy_readings
WHERE device_id = 'sensor_alpha'
ORDER BY time DESC
LIMIT 50;
```

```text
Index configured as: (device_id, time DESC)

[ device_id = 'sensor_alpha' ]
  ├── 14:00:00  <-- Pointer lands at root/top; reads sequentially downward
  ├── 13:59:59
  ├── 13:59:58
  └── [Scans 50 rows -> Halts immediately (Index Scan)]
```

* **With `(device_id, time DESC)`:** The query engine locates the device key and traverses sequentially down the newest timestamps, terminating the scan the moment the `LIMIT` is satisfied.
* **Without `DESC` (Default `ASC`):** Although single-key indexes can be read backward, composite indexes combined with multi-column sorting or auxiliary filters can break bidirectional traversal. PostgreSQL may fail over to fetching candidate sets into working memory (`Sort` / `Incremental Sort`), degrading p99 query latency.

---

## 4. Continuous Aggregates vs. Materialized Views

Both continuous aggregates and materialized views summarize granular records (such as 1-second ticks into 1-hour rollups) to serve analytical dashboards without recomputing millions of rows per request. However, their internal execution models differ fundamentally:

| Feature | Standard PostgreSQL Materialized View | TimescaleDB Continuous Aggregate |
| :--- | :--- | :--- |
| **Refresh Strategy** | **All-or-Nothing:** Complete historical invalidation and full recalculation from scratch. | **Incremental Windowing:** Calculates only newly ingested data since the last execution. |
| **Hardware Overhead** | Severe I/O and CPU spikes; long-running read/write locks. | Asynchronous, low-overhead background workers. |
| **Downstream Data Drops** | Dropping underlying raw points clears historical rollup aggregates on subsequent refresh. | Aggregated summaries remain fully intact even when underlying raw chunks are purged. |
| **Query Freshness** | Stale until an explicit manual refresh command runs. | **Real-Time Aggregates:** Seamlessly unions materialized buckets with unaggregated real-time records. |

---

## 5. Continuous Aggregate Refresh Policies

A **Refresh Policy** defines an automated schedule dictating window recalculations for continuous aggregate views.

```sql
SELECT add_continuous_aggregate_policy(
  'energy_hourly',
  start_offset      => INTERVAL '3 hours',
  end_offset        => INTERVAL '1 hour',
  schedule_interval => INTERVAL '30 minutes'
);
```

### Parameter Breakdown

```text
Timeline Overview:
[----------- Historic Data -----------][--- Window to Recalculate ---][-- Unfinished Window --]
                                       |                              |
                                  start_offset                   end_offset
                                  (3 hours ago)                  (1 hour ago)               NOW
```

* **`schedule_interval => INTERVAL '30 minutes'`**  
  Background workers trigger this policy job every 30 minutes.
* **`end_offset => INTERVAL '1 hour'` (Incomplete Bucket Exclusion)**  
  Skips aggregation over the current, unsealed hour. If it is 02:40 PM, the `02:00 - 03:00 PM` bucket is still accepting real-time writes. Pre-computing it would trigger redundant invalidations.
* **`start_offset => INTERVAL '3 hours'` (Late-Arriving Telemetry Catch-up)**  
  Extends the lookback window to cover up to 3 hours ago. When field edge devices temporarily drop connectivity and dump backlogged buffers upon reconnection, this setting incorporates their late data into prior hourly summaries.

---

# Part II: MQTT Protocol Architecture

**MQTT** (*Message Queuing Telemetry Transport*) is an open-standard (OASIS/ISO), extremely lightweight publish/subscribe transport designed for high-latency, constrained-bandwidth, or unstable physical communication links.

## 1. Publish/Subscribe (Pub/Sub) Model

Unlike synchronous request-response client-server architectures, MQTT decouples the producer (**Publisher**) and consumer (**Subscriber**) through a centralized routing engine (**Broker**).

```text
[ Sensor Node ]
      │
      │  PUBLISH: "home/living-room/temperature" (Payload: 22.4 C)
      ▼
+-------------------------------------------------------------+
|                         MQTT BROKER                         |
|      (e.g., Mosquitto, EMQX, HiveMQ, AWS IoT Core)          |
+-------------------------------------------------------------+
      │                                       │
      │ FORWARD                               │ FORWARD
      ▼                                       ▼
[ Mobile Application ]              [ Ingestion Microservice ]
(Subscribed: "home/+/temperature")  (Subscribed: "home/#")
```

### Structural Components

* **The Broker:** Central coordinator handling authentication, authorization, session state, connection lifecycles, and route dispatching.
* **Publishers:** Edge nodes transmitting payload buffers annotated with UTF-8 topic strings.
* **Subscribers:** Downstream clients declaring subscription filters to receive matching payloads.
* **Decoupling Dimensions:**
    * **Space Decoupling:** Publishers and subscribers operate without knowledge of counterpart IP addresses or host topologies.
    * **Time Decoupling:** With persistent sessions, subscribers can process packets published while they were offline.
    * **Synchronization Decoupling:** Message production and consumption occur asynchronously without thread blocking.

---

## 2. Topic Hierarchies & Wildcards

Topics use hierarchical, forward-slash-delimited paths:
```text
energyiq/us-east/substation_04/inverter_01/telemetry
```

### Topic Wildcards (Subscriptions Only)

> **Important:** Wildcards are strictly valid for client subscriptions and must never appear inside published message topics.

#### 1. Single-Level Wildcard: `+`
Matches exactly one topic tier between adjacent delimiters.

* **Pattern:** `home/+/temperature`
    * Matches: `home/kitchen/temperature`
    * Matches: `home/living-room/temperature`
    * Does **NOT** Match: `home/ground-floor/kitchen/temperature` *(exceeds one level)*

#### 2. Multi-Level Wildcard: `#`
Matches all nested child tiers down to the leaf node. **Must always sit as the terminal character.**

* **Pattern:** `home/ground-floor/#`
    * Matches: `home/ground-floor/temperature`
    * Matches: `home/ground-floor/kitchen/temperature`
    * Matches: `home/ground-floor/kitchen/humidity/raw`

---

## 3. Quality of Service (QoS) Levels

QoS contracts define message delivery guarantees between clients and brokers across the transport layer:

```text
+-------+-------------------------+--------------------------------------------------------+
| Level | Guarantee               | Protocol Mechanism                                    |
+-------+-------------------------+--------------------------------------------------------+
| QoS 0 | At most once (<= 1)     | Fire-and-forget; no ACK response sent.                 |
| QoS 1 | At least once (>= 1)    | Handshake: PUBLISH -> PUBACK (duplicates possible).    |
| QoS 2 | Exactly once (= 1)      | 4-way handshake: PUBLISH -> PUBREC -> PUBREL -> PUBCOMP|
+-------+-------------------------+--------------------------------------------------------+
```

---

## 4. Architectural Comparison: MQTT vs. HTTP

| Engineering Dimension | MQTT (Message Queuing Telemetry Transport) | HTTP/1.1 & HTTP/2 (REST) |
| :--- | :--- | :--- |
| **Communication Paradigm** | Asynchronous Publish / Subscribe (Event-Driven) | Synchronous Request / Response (Client / Server) |
| **Transport Lifecycle** | Persistent, stateful TCP connection maintained via low-cost keep-alive heartbeats (`PINGREQ`/`PINGRESP`). | Primarily transient, request-bound connections (or persistent connections carrying high protocol baggage). |
| **Header Overhead** | Fixed packet header as low as **2 bytes**. | Verbose ASCII headers frequently exceeding **200 to 800+ bytes** per HTTP call. |
| **Power & Hardware Cost** | Minimal parsing overhead; suited for ultra-low-power microcontrollers (ESP32, STM32). | High CPU parsing cycles, TLS handshakes, and memory overhead drain edge battery reserves. |
| **Data Push Mechanism** | **Native server push:** The broker pushes messages to clients immediately upon arrival. | Requires client polling loops, Server-Sent Events (SSE), or secondary WebSocket handshakes. |
| **Delivery Guarantees** | Protocol-level delivery semantics (**QoS 0, 1, 2**). | Relies entirely on application-layer retry mechanisms and idempotency tokens. |

---

## 5. Industry Use Cases

```text
                    +------------------------+
                    |  IoT & Sensor Systems  |
                    +-----------+------------+
                                |
       +------------------------+------------------------+
       |                        |                        |
       v                        v                        v
[ Smart Home & Edge ]   [ Energy & Utilities ]   [ Industrial / IIoT ]
 Home Assistant, Zigbee  Solar Inverters, Smart   SCADA, Factory PLCs,
 and room sensors        Meters, Grid balancing   Sparkplug B pipelines
       |                        |                        |
       +------------------------+------------------------+
                                |
       +------------------------+------------------------+
       |                                                 |
       v                                                 v
[ Connected Fleet / Telematics ]                 [ Instant Messaging ]
 CAN-bus telemetry, GPS trackers,                Low-bandwidth, high-concurrency
 cross-country cellular telemetry                mobile push architectures
```

* **Smart Home & Residential Automation:** Local brokers coordinate Zigbee/Z-Wave bridges, smart plugs, climate controls, and Home Assistant nodes.
* **Smart Grid & Telemetry Ingestion:** Grid sub-meters and utility-scale solar arrays stream split-second phase voltage, active load, and temperature data to time-series backends.
* **Industrial IoT (IIoT):** Manufacturing facilities run MQTT architectures wrapping legacy fieldbus systems using **Sparkplug B** to contextualize PLC payloads.
* **Connected Logistics & Telematics:** Fleet trackers stream asset coordinates, engine diagnostics, and cold-chain temperature telemetry across lossy 3G/4G/5G cellular zones.
* **Mobile Messaging Platforms:** Mobile push services rely on modified MQTT client agents to sustain persistent connections while minimizing cellular radio battery consumption.

# 🏢 Part 1: The Architecture (Why 2 Devices & 1 Bridge User?)

We designed a secure, production-grade multitenant MQTT architecture. In IoT systems, letting every device access everything is a major security flaw. If one device gets physically compromised, an attacker could control your entire network.

To prevent this, we established strict **least-privilege access control (ACL)** using three specific roles:

### 1. `device-001` and `device-002` (Isolated IoT Clients)
* **Their Role:** These represent actual physical hardware sensors out in the field (e.g., smart meters monitoring power usage).
* **Why Separate?** Each device gets its own distinct username and password.
* **The Security Boundary:** Back in Step 3, you configured an ACL pattern: `pattern readwrite energyiq/devices/%u/#`. Because of this, `device-001` can only publish/subscribe to `energyiq/devices/device-001/...`. It cannot peek at `device-002`'s data, nor can it spoof messages pretending to be `device-002`.

### 2. `bridge-user` (The Central Aggregator)
* **Its Role:** This user does not belong to a physical sensor. Instead, it is an internal backend application service (like an MQTT-to-Kafka or MQTT-to-Postgres broker) running on your server.
* **Why Does It Exist?** Your backend application needs to collect telemetry from all devices simultaneously to process analytics.
* **The Security Boundary:** In your `acl.conf`, you granted this specific user global clearance: `topic readwrite energyiq/devices/#`. The multi-level wildcard (`#`) allows the backend bridge to intercept, monitor, and route data coming from every single device on the network while the devices themselves remain totally blind to one another.

---

# 🛠️ Part 2: Detailed Command Breakdown

Because your local machine doesn't have Mosquitto's specialized security utilities natively installed, we used a throwaway Docker container as an isolated toolbench to generate the password file.

### 🟥 Command 1: Creating the Initial File

```bash
docker run --rm -v "./:/mosquitto/config" \
  eclipse-mosquitto:2.0 \
  mosquitto_passwd -b -c /mosquitto/config/passwords device-001 pass-001
```

* `docker run`: Tells Docker to pull down and spin up an isolated virtual machine container instance.
* `--rm`: Automatically remove the container the millisecond it finishes executing the command. This prevents hundreds of old, dead utility containers from cluttering your computer's disk space.
* `-v "./:/mosquitto/config"`: Creates a volume bind mount. It maps your current local folder (`./` where your config files sit) directly to the internal configuration folder inside the container (`/mosquitto/config`). This means anything the container writes to `/mosquitto/config` is safely saved directly onto your laptop's hard drive.
* `eclipse-mosquitto:2.0`: The exact Docker image engine to boot up.
* `mosquitto_passwd`: The specialized binary command line application inside the container that hashes usernames and passwords.
* `-b`: Stands for **Batch Mode**. Normally, `mosquitto_passwd` stops execution and interactively asks you to type and verify a hidden password. Passing `-b` allows you to supply the username and password explicitly right inside the terminal command inline.
* `-c`: Stands for **Create**. This instructs the program to completely wipe any file called `passwords` if it already exists and create a brand new, empty database file.
* `/mosquitto/config/passwords`: The file path inside the container where the output should be written (which targets your local folder via our volume mount).
* `device-001 pass-001`: The cleartext username and password payload passed to the compiler.

### 🟨 Commands 2 & 3: Appending Additional Users

```bash
mosquitto_passwd -b /mosquitto/config/passwords device-002 pass-002
```

> [!IMPORTANT]
> Notice that the `-c` flag is missing here! If you left the `-c` flag on for command #2, it would completely overwrite and delete `device-001`. By removing `-c`, you tell the utility to carefully open the existing file, append `device-002` (and later `bridge-user`) to the bottom of the list, and re-save everything.

---

# 🔐 Part 3: Cryptographic Password Hashing

Mosquitto does not store your passwords in clear text. If an attacker managed to read your passwords file, they wouldn't see `pass-001`. Instead, the `mosquitto_passwd` tool performs a security function known as **password hashing with a salt**:

