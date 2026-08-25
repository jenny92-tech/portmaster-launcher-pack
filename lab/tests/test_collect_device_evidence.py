import unittest

from lab.collect_device_evidence import (
    appmanager_launcher_paths,
    loader_library_paths,
    split_endpoint,
)


class DeviceEvidenceTests(unittest.TestCase):
    def test_split_endpoint_uses_default_port(self) -> None:
        self.assertEqual(split_endpoint("192.0.2.10", 22), ("192.0.2.10", 22))

    def test_split_endpoint_reads_explicit_port(self) -> None:
        self.assertEqual(
            split_endpoint("192.0.2.11:5555", 22), ("192.0.2.11", 5555)
        )

    def test_loader_paths_are_bounded_to_runtime_library_directories(self) -> None:
        evidence = """
===== appmanager-loader-resolution =====
libSDL2-2.0.so.0 => /usr/lib64/libSDL2-2.0.so.0 (0x01)
libc.so.6 => /lib64/libc.so.6 (0x02)
/lib/ld-linux-aarch64.so.1 (0x03)
libbad.so => /etc/private.so (0x04)
===== hardware-interfaces =====
"""
        self.assertEqual(
            loader_library_paths(evidence),
            [
                "/lib/ld-linux-aarch64.so.1",
                "/lib64/libc.so.6",
                "/usr/lib64/libSDL2-2.0.so.0",
            ],
        )

    def test_launcher_paths_come_only_from_the_launcher_section(self) -> None:
        evidence = """
missing /outside/APP Manager.sh
===== appmanager-launchers =====
--- /mnt/card/ports/APP Manager.sh ---
#!/bin/sh
===== static-launch-environment =====
--- /ignored/APP Manager.sh ---
"""
        self.assertEqual(
            appmanager_launcher_paths(evidence),
            ["/mnt/card/ports/APP Manager.sh"],
        )


if __name__ == "__main__":
    unittest.main()
