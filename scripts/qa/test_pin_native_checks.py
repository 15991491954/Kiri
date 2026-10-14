import unittest
from unittest.mock import patch
from pathlib import Path
import tempfile
import shutil

from pin_native_checks import borderless_geometry_evidence, capture_origin_evidence, pin_content_evidence, pin_lifecycle_evidence, pin_open_log_marker, pin_outline_evidence, proportional_resize_evidence
from windows_qa_profile import isolated_app_directories, isolated_windows_profile

try:
    from PIL import Image, ImageDraw
except ImportError:
    Image = ImageDraw = None


@unittest.skipIf(Image is None, "Pixel assertions require Pillow, as installed in native desktop QA")
class NativePinPixelChecks(unittest.TestCase):
    def framed_image(self, scale):
        size = (round(580 * scale), round(235 * scale))
        reference = Image.new("RGB", size, "white")
        actual = reference.copy()
        ImageDraw.Draw(actual).rounded_rectangle(
            (0, 0, size[0] - 1, size[1] - 1), radius=round(8 * scale),
            outline="#111111", width=round(2 * scale))
        return actual, reference

    def test_frame_is_independent_of_content_at_integer_and_fractional_dpi(self):
        for scale, inset in [(1, 4), (1.25, 5), (1.5, 6), (2, 8)]:
            with self.subTest(scale=scale):
                actual, reference = self.framed_image(scale)
                proof = pin_content_evidence(actual, reference, scale)
                self.assertEqual(proof["mean_pixel_error"], 0)
                self.assertEqual(proof["content_inset_physical"], inset)
                self.assertTrue(pin_outline_evidence(actual, reference, scale)["visible"])

    def test_content_occlusion_still_exceeds_the_original_threshold(self):
        for scale in [1, 1.25, 1.5, 2]:
            with self.subTest(scale=scale):
                actual, reference = self.framed_image(scale)
                ImageDraw.Draw(actual).rectangle(
                    (round(100 * scale), round(80 * scale), round(200 * scale), round(180 * scale)),
                    fill="black")
                self.assertGreater(pin_content_evidence(actual, reference, scale)["mean_pixel_error"], 3)

    def test_every_frame_side_must_be_dark_and_visible(self):
        for scale in [1, 1.25, 1.5, 2]:
            actual, reference = self.framed_image(scale)
            points = pin_outline_evidence(actual, reference, scale)["side_sample_points"]
            for point in points:
                with self.subTest(scale=scale, point=point):
                    missing_side = actual.copy()
                    missing_side.putpixel(point, (255, 255, 255))
                    with self.assertRaisesRegex(RuntimeError, "missing a dark, visible frame side"):
                        pin_outline_evidence(missing_side, reference, scale)

    def test_a_visible_but_light_frame_is_rejected(self):
        actual, reference = self.framed_image(1)
        for point in pin_outline_evidence(actual, reference, 1)["side_sample_points"]:
            actual.putpixel(point, (150, 150, 150))
        with self.assertRaisesRegex(RuntimeError, "missing a dark, visible frame side"):
            pin_outline_evidence(actual, reference, 1)

    def test_invalid_scale_and_unusable_dimensions_are_rejected(self):
        actual, reference = self.framed_image(1)
        for helper in [pin_content_evidence, pin_outline_evidence]:
            for scale in [0, -1, float("nan"), float("inf")]:
                with self.subTest(helper=helper.__name__, scale=scale), self.assertRaises(RuntimeError):
                    helper(actual, reference, scale)
            with self.assertRaises(RuntimeError):
                helper(actual, reference.resize((579, 235)), 1)
            with self.assertRaises(RuntimeError):
                helper(actual.resize((8, 8)), reference.resize((8, 8)), 1)


class NativePinChecks(unittest.TestCase):
    asset = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"

    def test_pin_must_match_capture_origin_and_size(self):
        selected = (470, 160, 1150, 420)
        self.assertTrue(capture_origin_evidence(selected, selected)["matches_capture_region"])
        for actual in [(0, 0, 680, 260), (470, 160, 1150, 640), (471, 161, 1151, 421)]:
            if actual == (471, 161, 1151, 421):
                capture_origin_evidence(actual, selected)
            else:
                with self.assertRaises(RuntimeError):
                    capture_origin_evidence(actual, selected)

    def trace(self, events, count=2):
        return f"completion queued until overlay destruction labels={count}\n" + "\n".join(events)

    @property
    def opened(self):
        return f"[pin] screenshot opened asset_id={self.asset}"

    def test_every_monitor_overlay_must_be_destroyed_before_pin(self):
        proof = pin_lifecycle_evidence(self.trace([
            "[window] destroyed label=overlay", "[window] destroyed label=overlay-2", self.opened]), self.asset)
        self.assertEqual(proof["destroyed_overlays"], ["overlay", "overlay-2"])

    def test_creation_between_two_overlay_destructions_is_rejected(self):
        with self.assertRaises(RuntimeError):
            pin_lifecycle_evidence(self.trace([
                "[window] destroyed label=overlay", self.opened, "[window] destroyed label=overlay-2"]), self.asset)

    def test_missing_or_duplicate_destruction_cannot_satisfy_monitor_count(self):
        for events in (["[window] destroyed label=overlay", self.opened],
                       ["[window] destroyed label=overlay", "[window] destroyed label=overlay", self.opened]):
            with self.subTest(events=events), self.assertRaises(RuntimeError):
                pin_lifecycle_evidence(self.trace(events), self.asset)

    def test_old_or_repeated_capture_trace_is_rejected(self):
        valid = self.trace(["[window] destroyed label=overlay", self.opened], count=1)
        for trace in (valid + valid, valid + "\n" + self.opened, self.trace([self.opened], count=0)):
            with self.subTest(trace=trace), self.assertRaises(RuntimeError):
                pin_lifecycle_evidence(trace, self.asset)

    def test_pin_for_another_asset_is_rejected(self):
        with self.assertRaises(RuntimeError):
            pin_lifecycle_evidence(self.trace(["[window] destroyed label=overlay", self.opened], count=1), "other")

    def test_swift_compatible_uppercase_index_matches_native_uuid_log(self):
        self.assertEqual(pin_open_log_marker(self.asset.upper()), self.opened)
        proof = pin_lifecycle_evidence(self.trace([
            "[window] destroyed label=overlay", self.opened], count=1), self.asset.upper())
        self.assertTrue(proof["pin_after_all_overlay_destroyed"])

    def test_native_rounding_is_allowed_but_noop_and_stretch_are_rejected(self):
        proportional_resize_evidence((580, 235), (638, 259))
        for after in ((580, 235), (640, 235), (640, 310), (0, 0)):
            with self.subTest(after=after), self.assertRaises(RuntimeError):
                proportional_resize_evidence((580, 235), after)

    def test_actual_nonclient_geometry_detects_titlebar_and_border(self):
        borderless_geometry_evidence((10, 20, 590, 255), (10, 20, 590, 255))
        for client in ((10, 44, 590, 255), (18, 28, 582, 247)):
            with self.subTest(client=client), self.assertRaises(RuntimeError):
                borderless_geometry_evidence(client, (10, 20, 590, 255))

    def test_profile_isolation_refuses_non_ci_and_self_hosted_machines(self):
        for environment in ({}, {"GITHUB_ACTIONS": "true", "RUNNER_ENVIRONMENT": "self-hosted"}):
            with self.subTest(environment=environment), patch.dict("os.environ", environment, clear=True):
                with self.assertRaisesRegex(RuntimeError, "disposable GitHub-hosted"):
                    with isolated_windows_profile():
                        self.fail("Unsafe profile redirection was accepted")

    def test_prior_app_data_restored_and_generated_data_removed_even_on_failure(self):
        for fail in (False, True):
            with self.subTest(fail=fail), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                existing, new, backup = root / "existing", root / "new", root / "backup"
                existing.mkdir(); backup.mkdir()
                (existing / "prior.txt").write_text("prior QA data")
                try:
                    with isolated_app_directories((existing, new), backup):
                        self.assertEqual(list(existing.iterdir()), [])
                        (existing / "capture.txt").write_text("generated capture")
                        (new / "capture.txt").write_text("generated capture")
                        if fail:
                            raise ValueError("desktop acceptance failed")
                except ValueError:
                    self.assertTrue(fail)
                self.assertEqual((existing / "prior.txt").read_text(), "prior QA data")
                self.assertFalse((existing / "capture.txt").exists())
                self.assertFalse(new.exists())
                self.assertEqual(list(backup.iterdir()), [])

    def test_linked_profile_is_rejected_before_touching_prior_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            prior, linked, backup = root / "prior", root / "linked", root / "backup"
            prior.mkdir(); backup.mkdir()
            (prior / "prior.txt").write_text("prior QA data")
            try:
                linked.symlink_to(prior, target_is_directory=True)
            except OSError:
                self.skipTest("This runner cannot create directory symlinks")
            with self.assertRaisesRegex(RuntimeError, "unexpected Kiri profile"):
                with isolated_app_directories((prior, linked), backup):
                    self.fail("Linked profile was accepted")
            self.assertEqual((prior / "prior.txt").read_text(), "prior QA data")
            self.assertEqual(list(backup.iterdir()), [])

    def test_webview_sharing_lock_retry_still_restores_prior_data(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, backup = root / "original", root / "backup"
            original.mkdir(); backup.mkdir()
            (original / "prior.txt").write_text("prior QA data")
            actual_remove = shutil.rmtree
            calls = []
            def release_then_remove(path):
                calls.append(path)
                if len(calls) == 1:
                    error = PermissionError("WebView cache handle pending release")
                    error.winerror = 32
                    raise error
                actual_remove(path)
            with patch("windows_qa_profile.shutil.rmtree", side_effect=release_then_remove), patch("windows_qa_profile.time.sleep"):
                with isolated_app_directories((original,), backup):
                    (original / "generated.txt").write_text("generated")
            self.assertEqual(len(calls), 2)
            self.assertEqual((original / "prior.txt").read_text(), "prior QA data")
            self.assertFalse((original / "generated.txt").exists())

    def test_nonsharing_cleanup_failure_preserves_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, backup = root / "original", root / "backup"
            original.mkdir(); backup.mkdir()
            (original / "prior.txt").write_text("prior QA data")
            with patch("windows_qa_profile.shutil.rmtree", side_effect=PermissionError("not a sharing lock")):
                with self.assertRaisesRegex(RuntimeError, "Could not restore"):
                    with isolated_app_directories((original,), backup):
                        pass
            self.assertEqual((backup / "original-0/prior.txt").read_text(), "prior QA data")

    def test_disappearing_webview_cache_file_still_removes_tree_and_restores_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, backup = root / "original", root / "backup"
            original.mkdir(); backup.mkdir()
            (original / "prior.txt").write_text("prior QA data")
            actual_remove, calls = shutil.rmtree, []
            def remove_after_cache_exit(path):
                calls.append(path)
                if len(calls) == 1:
                    (path / "lockfile").unlink()
                    raise FileNotFoundError("WebView cache file disappeared")
                actual_remove(path)
            with patch("windows_qa_profile.shutil.rmtree", side_effect=remove_after_cache_exit):
                with isolated_app_directories((original,), backup):
                    (original / "lockfile").write_text("generated")
                    (original / "other-cache").write_text("generated")
            self.assertEqual(len(calls), 2)
            self.assertEqual((original / "prior.txt").read_text(), "prior QA data")
            self.assertFalse((original / "other-cache").exists())
            self.assertEqual(list(backup.iterdir()), [])

    def test_already_removed_generated_tree_restores_backup(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, backup = root / "original", root / "backup"
            original.mkdir(); backup.mkdir()
            (original / "prior.txt").write_text("prior QA data")
            actual_remove, calls = shutil.rmtree, []
            def remove_then_report_missing(path):
                calls.append(path)
                actual_remove(path)
                raise FileNotFoundError("Generated directory was removed")
            with patch("windows_qa_profile.shutil.rmtree", side_effect=remove_then_report_missing):
                with isolated_app_directories((original,), backup):
                    (original / "generated.txt").write_text("generated")
            self.assertEqual(len(calls), 1)
            self.assertEqual((original / "prior.txt").read_text(), "prior QA data")

    def test_repeated_missing_cache_failure_does_not_hide_unremoved_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original, backup = root / "original", root / "backup"
            original.mkdir(); backup.mkdir()
            (original / "prior.txt").write_text("prior QA data")
            with patch("windows_qa_profile.shutil.rmtree", side_effect=FileNotFoundError("cache race")), patch("windows_qa_profile.time.monotonic", side_effect=[0, 21]):
                with self.assertRaisesRegex(RuntimeError, "Could not restore"):
                    with isolated_app_directories((original,), backup):
                        (original / "generated.txt").write_text("generated")
            self.assertEqual((backup / "original-0/prior.txt").read_text(), "prior QA data")
            self.assertTrue((original / "generated.txt").exists())


if __name__ == "__main__":
    unittest.main()
