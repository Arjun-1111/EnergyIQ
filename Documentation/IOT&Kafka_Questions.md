# 🏗️ Architecture & Design Decisions

This document explains the core technical decisions behind our IoT messaging and Apache Kafka infrastructure. It serves as a guide for developers and operators to understand the "why" behind our configurations.

---

## 📡 1. QoS 0 vs 1 vs 2: Which should IoT devices use?

Quality of Service (QoS) is a messaging agreement between a sender (IoT device) and a receiver (Broker) that defines how strictly a message must be delivered.

Here is the breakdown of the three levels:

### QoS 0: "At Most Once" (Fire and Forget)
* **How it works:** The device sends a message and doesn't wait for a reply. If the network drops or the broker restarts, the message is permanently lost.
* **When to use it:** High-frequency, low-value telemetry. For example, a temperature sensor sending readings every 1 second. If you lose one reading, the next one arrives a second later. It requires the least amount of battery and bandwidth.

### QoS 1: "At Least Once" (Guaranteed Delivery)
* **How it works:** The device sends a message and waits for an acknowledgment (ACK). If it doesn't get the ACK in time, it sends the message again. The message is guaranteed to arrive, but you might receive duplicates if the ACK was simply delayed by network lag.
* **When to use it:** **This is the recommended default for most IoT devices.** It ensures you never lose critical data (like a smart meter reading or a security alarm). Your backend systems just need to be designed to ignore accidental duplicate messages.

### QoS 2: "Exactly Once" (No Duplicates)
* **How it works:** Uses a heavy, 4-step handshake to guarantee the message arrives once and *only* once.
* **When to use it:** Almost never in standard IoT. The extensive handshake consumes significant battery power and chokes constrained cellular networks. It is typically reserved for critical financial transactions or medical billing where duplicates cause severe harm.

> **💡 The Verdict for IoT:** Default your devices to **QoS 1** for reliable telemetry. Only drop down to **QoS 0** if the device has severe battery constraints and sends highly repetitive data.

---

## 🔒 2. Why is `AUTO_CREATE_TOPICS_ENABLE` set to `false`?

By default, Kafka can automatically create a new topic the exact moment a producer or consumer requests it. While this sounds convenient for development, we explicitly disable it (`false`) for production-grade environments for three major reasons:

1. **The "Typo" Disaster:**
   If a developer makes a typo in their device code (e.g., sending data to `raw-telemtery` instead of `raw-telemetry`), Kafka will silently create the misspelled topic and accept the data. Your backend consumers, listening to the correct topic, will see nothing. You will silently lose data without any errors being thrown.
2. **Loss of Configuration Control:**
   Topics require specific tuning based on their workload (e.g., partition counts for parallel processing, replication factors for high availability). Auto-created topics use generic default settings, completely bypassing your intended architectural design.
3. **Resource Exhaustion Attacks:**
   A malfunctioning IoT device or a malicious script could generate thousands of randomly named topics in seconds, crashing your Kafka broker by exhausting its memory and storage.

Setting this to `false` forces us to explicitly define our infrastructure as code, ensuring typos immediately throw an error so they can be fixed.

---

## 🗺️ 3. Why do we need multiple Advertised Listener addresses?

Kafka handles networking differently than a standard web server like Nginx or Apache. When a client (like an IoT gateway or a Python script) connects to Kafka, the first thing it does is ask the broker for a "map" of where to send its actual data.

The `KAFKA_ADVERTISED_LISTENERS` setting defines that map. We need multiple addresses because **clients approach the broker from different network boundaries**, and they need directions written in a language their specific network understands.

### The Network Boundaries:
* **The Internal Docker Network (`energyiq-kafka:9092`):**
  If a Flink stream-processor or a Node.js microservice is running inside the same Docker network, it understands Docker's internal DNS. It can use the container name `energyiq-kafka` to reach the broker securely.
* **The Host Machine / External (`localhost:9094`):**
  If a developer writes a Python script on their laptop to read messages, their laptop has no idea what `energyiq-kafka` means. To the laptop, the broker is accessible via `localhost` on a mapped port.
* **The Local CLI (`127.0.0.1:9091`):**
  When an administrator runs a Kafka shell script *inside* the container itself (using `docker exec`), they are standing right next to the broker and just need the local loopback address.

If Kafka only advertised a single address, clients from the other two boundaries would receive a map they couldn't read, causing their connections to fail instantly.