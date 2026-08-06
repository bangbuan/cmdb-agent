#!/usr/init/env python3
import sys
import json
import subprocess

def main():
    if len(sys.argv) < 4:
        print(json.dumps([]))
        return

    vm_json_str = sys.argv[1]
    vm_name = sys.argv[2]
    vm_state = sys.argv[3]

    try:
        data = json.loads(vm_json_str)
        storage_list = data.get("storage", [])
        
        enriched_storage = []
        for disk in storage_list:
            target = disk.get("target")
            capacity = 0
            allocation = 0
            physical = 0
            
            # domblkinfo hanya bisa diambil akurat jika VM aktif/running
            if vm_state == "running" and target:
                try:
                    cmd = ["virsh", "domblkinfo", vm_name, target]
                    res = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
                    if res.returncode == 0:
                        for line in res.stdout.splitlines():
                            parts = line.split(":")
                            if len(parts) == 2:
                                key = parts[0].strip().lower()
                                val = int(parts[1].strip())
                                if key == "capacity":
                                    capacity = val
                                elif key == "allocation":
                                    allocation = val
                                elif key == "physical":
                                    physical = val
                except Exception:
                    pass

            disk["capacity_bytes"] = capacity
            disk["allocation_bytes"] = allocation
            disk["physical_bytes"] = physical
            enriched_storage.append(disk)

        print(json.dumps(enriched_storage))
    except Exception:
        print(json.dumps([]))

if __name__ == "__main__":
    main()