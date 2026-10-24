// Only the isolated harness config aliases this file into QrResults.
export type { AssetDto, QrCodeDto, QrScanDto } from "../../src/lib/ipc";
const base = "/src-tauri/tests/fixtures/qr/";
const listeners = new Set<() => void>();
export const mediaUrl = (id: string) => base + id + ".png";
export const onLibraryChanged = async (callback: () => void) => { listeners.add(callback); return () => listeners.delete(callback); };
const log = (name: string) => { const output=document.querySelector("#qa-actions");if(output)output.textContent=name; };
export const api = {
  qrAction: async (_request: string, index: number, action: string) => {
    log(`Mock action: ${index} / ${action}`);
    if (action === "open" && new URLSearchParams(location.search).get("failOpen") === "1") throw "Could not open this link.";
    return null;
  },
  scanQr: async () => { throw "Harness does not perform native scans."; },
  cancelQr: async () => {},
};
