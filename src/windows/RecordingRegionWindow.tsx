import "./recording-region.css";

// The native window owns the selected region's exact logical frame, ignores
// pointer input, and is excluded from the recording alongside the controls.
export function RecordingRegionWindow() {
  return <div className="recording-region" aria-hidden="true" />;
}
