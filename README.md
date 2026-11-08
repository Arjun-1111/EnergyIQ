# EnergyIQ
Smart Energy Monitoring Platform

**Note: This is a work in progress and not yet ready for production use.*

**Docker Command to create the mosquitto password file: **
```
docker run --rm -v "./:/mosquitto/config" \
eclipse-mosquitto:2.0 \
mosquitto_passwd -b -c /mosquitto/config/passwords device-001 pass-001
```




