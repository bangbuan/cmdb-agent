#!/usr/bin/env python3
import sys
import json
import xml.etree.ElementTree as ET

def main():
    try:
        xml_str = sys.stdin.read()
        if not xml_str.strip():
            print(json.dumps({}))
            return

        root = ET.fromstring(xml_str)

        # UUID
        uuid_elem = root.find("uuid")
        uuid = uuid_elem.text.strip() if uuid_elem is not None and uuid_elem.text else ""

        # Title & Description
        title_elem = root.find("title")
        title = title_elem.text.strip() if title_elem is not None and title_elem.text else ""
        
        desc_elem = root.find("description")
        desc = desc_elem.text.strip() if desc_elem is not None and desc_elem.text else ""

        # vCPUs
        vcpu_elem = root.find("vcpu")
        vcpus = int(vcpu_elem.text.strip()) if vcpu_elem is not None and vcpu_elem.text else 0

        # Memory (dalam KiB di XML)
        memory_elem = root.find("memory")
        memory_kb = int(memory_elem.text.strip()) if memory_elem is not None and memory_elem.text else 0
        memory_mb = memory_kb // 1024

        # Storage Devices
        storage = []
        for disk in root.findall(".//devices/disk"):
            device_type = disk.get("device", "disk")
            target_elem = disk.find("target")
            target = target_elem.get("dev") if target_elem is not None else "unknown"
            
            source_type = disk.get("type", "")
            source = ""
            if source_type == "file":
                source_elem = disk.find("source")
                source = source_elem.get("file") if source_elem is not None else ""
            elif source_type == "block":
                source_elem = disk.find("source")
                source = source_elem.get("dev") if source_elem is not None else ""
            elif source_type == "network":
                source_elem = disk.find("source")
                source = source_elem.get("name", "") if source_elem is not None else ""

            storage.append({
                "type": source_type,
                "device": device_type,
                "source": source,
                "target": target
            })

        # Network Interfaces
        network = []
        for interface in root.findall(".//devices/interface"):
            net_type = interface.get("type", "unknown")
            source = interface.find("source")
            source_val = "unknown"
            if source is not None:
                source_val = source.get("bridge") or source.get("dev") or source.get("network") or "unknown"
            
            mac = interface.find("mac")
            mac_val = mac.get("address") if mac is not None else "unknown"
            
            target = interface.find("target")
            target_val = target.get("dev") if target is not None else "unknown"

            network.append({
                "type": net_type,
                "source": source_val,
                "mac": mac_val,
                "target": target_val
            })

        print(json.dumps({
            "uuid": uuid,
            "title": title,
            "description": desc,
            "vcpus": vcpus,
            "ram_mb": memory_mb,
            "storage": storage,
            "network": network
        }))

    except Exception as e:
        print(json.dumps({"error": str(e)}))

if __name__ == "__main__":
    main()