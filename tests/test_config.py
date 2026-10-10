import os
import pathlib
import shutil
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
CONFIG = ROOT / "config" / "deployment.env"
PRINT_NAMES = 'printf "%s|%s|%s" "$AZURE_RESOURCE_GROUP" "$AKS_CLUSTER_NAME" "$ACR_NAME"'


class ConfigurationTest(unittest.TestCase):
    def environment(self, **values):
        env = os.environ.copy()
        for name in ("AZURE_RESOURCE_GROUP", "AKS_CLUSTER_NAME", "ACR_NAME"):
            env.pop(name, None)
        env.update(values)
        return env

    def source(self, path, env):
        return subprocess.run(
            ["bash", "-c", 'source "$1"; ' + PRINT_NAMES, "config-test", str(path)],
            env=env, capture_output=True, text=True, timeout=10,
        )

    def test_public_config_has_no_deployment_coordinates(self):
        result = self.source(CONFIG, self.environment())
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "||")

    def test_exported_coordinates_are_preserved(self):
        result = self.source(CONFIG, self.environment(
            AZURE_RESOURCE_GROUP="example-rg",
            AKS_CLUSTER_NAME="example-cluster",
            ACR_NAME="exampleregistry",
        ))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "example-rg|example-cluster|exampleregistry")

    def fixture(self, root):
        (root / "scripts").mkdir()
        (root / "config").mkdir()
        shutil.copyfile(ROOT / "scripts/common.sh", root / "scripts/common.sh")
        shutil.copyfile(CONFIG, root / "config/deployment.env")
        return root / "scripts/common.sh"

    def test_missing_coordinates_fail_before_cloud_access(self):
        with tempfile.TemporaryDirectory(prefix="substrate-config-") as temporary:
            root = pathlib.Path(temporary)
            result = self.source(self.fixture(root), self.environment())
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Set AZURE_RESOURCE_GROUP", result.stderr)
            self.assertFalse((root / ".state").exists())

    def test_local_env_overrides_exported_coordinates(self):
        with tempfile.TemporaryDirectory(prefix="substrate-config-") as temporary:
            root = pathlib.Path(temporary)
            common = self.fixture(root)
            (root / ".env").write_text(
                "AZURE_RESOURCE_GROUP=local-rg\n"
                "AKS_CLUSTER_NAME=local-cluster\n"
                "ACR_NAME=localregistry\n"
            )
            (root / ".state").mkdir()
            (root / ".state/subscription-id").write_text("example-subscription\n")
            result = self.source(common, self.environment(
                AZURE_RESOURCE_GROUP="exported-rg",
                AKS_CLUSTER_NAME="exported-cluster",
                ACR_NAME="exportedregistry",
            ))
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, "local-rg|local-cluster|localregistry")


if __name__ == "__main__":
    unittest.main()
