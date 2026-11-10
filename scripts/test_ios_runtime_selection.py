"""Simulator selection must not silently mix a newer runtime with an older SDK."""
import unittest
from run_ios_runtime_probe import select_iphone


class RuntimeSelectionTests(unittest.TestCase):
    def inventory(self):
        return {'devices': {
            'com.apple.CoreSimulator.SimRuntime.iOS-26-2': [{'name': 'iPhone 17', 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-18-5': [{'name': 'iPhone 16', 'isAvailable': True}],
            'com.apple.CoreSimulator.SimRuntime.iOS-18-1': [{'name': 'iPhone 15', 'isAvailable': True}],
        }}

    def test_arm_uses_newest_within_selected_sdk(self):
        runtime, _ = select_iphone(self.inventory(), '18.5', 'arm64')
        self.assertTrue(runtime.endswith('iOS-18-5'))

    def test_newer_sdk_keeps_newer_runtime_coverage(self):
        runtime, _ = select_iphone(self.inventory(), '26.2', 'arm64')
        self.assertTrue(runtime.endswith('iOS-26-2'))

    def test_intel_preserves_oldest_available_runtime(self):
        runtime, _ = select_iphone(self.inventory(), '18.5', 'x86_64')
        self.assertTrue(runtime.endswith('iOS-18-1'))

    def test_incompatible_inventory_is_an_error(self):
        with self.assertRaises(RuntimeError):
            select_iphone(self.inventory(), '17.4', 'arm64')

    def test_unavailable_and_other_devices_do_not_count(self):
        inventory = self.inventory()
        inventory['devices']['com.apple.CoreSimulator.SimRuntime.iOS-18-5'] = [
            {'name': 'iPhone unavailable', 'isAvailable': False}, {'name': 'iPad Pro', 'isAvailable': True}]
        runtime, _ = select_iphone(inventory, '18.5', 'arm64')
        self.assertTrue(runtime.endswith('iOS-18-1'))


if __name__ == '__main__':
    unittest.main()
