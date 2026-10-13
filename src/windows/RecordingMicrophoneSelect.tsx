import { useEffect, useRef, useState } from "react";
import { ChoiceSelect } from "../components/ChoiceSelect";
import { t } from "../i18n";
import { api, type RecordingOptions } from "../lib/ipc";

export default function RecordingMicrophoneSelect({ options, disabled, onChange }: {
  options: RecordingOptions; disabled: boolean; onChange(options: RecordingOptions): void;
}) {
  const [devices, setDevices] = useState<{ id: string; name: string }[]>([]);
  const [status, setStatus] = useState<"idle" | "loading" | "failed">("idle");
  const request = useRef(0);
  useEffect(() => () => { request.current++; }, []);
  const refresh = () => {
    const current = ++request.current;
    setStatus("loading");
    void api.listMicrophoneDevices().then(value => {
      if (current !== request.current) return;
      setDevices(value);
      setStatus("idle");
    }).catch(() => {
      if (current === request.current) setStatus("failed");
    });
  };
  const selectedUnavailable = !!options.microphoneDeviceId && !devices.some(device => device.id === options.microphoneDeviceId);
  return <ChoiceSelect value={options.microphoneDeviceId ?? ""} disabled={disabled}
    label={t("Choose microphone")} menuHeader={t("Choose microphone")}
    className="kiri-record-options__microphone" menuClassName="kiri-record-device-menu" menuMinWidth={280}
    menuStatus={status === "loading" ? t("Loading microphones…") : status === "failed" ? t("Unable to load microphones")
      : selectedUnavailable ? t("Selected microphone is unavailable") : undefined}
    options={[{ value: "", label: t("System default microphone") }, ...devices.map(device => ({ value: device.id, label: device.name }))]}
    onOpen={refresh} onChange={id => onChange({ ...options, usesCountdown: true, capturesMicrophone: true, microphoneDeviceId: id || null })} />;
}
