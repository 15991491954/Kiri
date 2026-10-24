import {useEffect,useRef,useState} from "react";
import {getCurrentWindow} from "@tauri-apps/api/window";
import {t} from "../i18n";
import {installVideoProjectShortcuts} from "./video-project-shortcuts.js";

/** A save/flush that never settles must not make the window unclosable. */
const PREPARE_CLOSE_TIMEOUT_MS=5000;

function within(work:Promise<boolean>,ms:number):Promise<boolean>{
  return Promise.race([
    work.catch(()=>false),
    new Promise<boolean>(resolve=>setTimeout(()=>resolve(false),ms)),
  ]);
}

/** Ordinary closes flush autosave silently. Only blocked closes need a dialog. */
export function VideoCloseGuard({busy,prepareClose}:{busy:boolean;prepareClose():Promise<boolean>}) {
  const state=useRef({busy,prepareClose});state.current={busy,prepareClose};
  const allowClose=useRef(false),closing=useRef(false);
  const dialog=useRef<HTMLDialogElement>(null);
  const [reason,setReason]=useState<"export"|"save"|null>(null);
  const [retrying,setRetrying]=useState(false);
  const requestClose=useRef<()=>Promise<void>>(async()=>{});
  requestClose.current=async()=>{
    if(closing.current)return;
    if(state.current.busy){setReason("export");return;}
    if(allowClose.current){void getCurrentWindow().close().catch(()=>{});return;}
    closing.current=true;setRetrying(true);
    try {
      const prepared=await within(Promise.resolve().then(()=>state.current.prepareClose()),PREPARE_CLOSE_TIMEOUT_MS);
      if(!prepared){setReason("save");return;}
      allowClose.current=true;
      await getCurrentWindow().close();
    } catch {
      setReason("save");
    } finally {closing.current=false;setRetrying(false);}
  };
  useEffect(()=>{
    let disposed=false;
    const subscription=getCurrentWindow().onCloseRequested(event=>{
      if(disposed||allowClose.current)return;
      event.preventDefault();void requestClose.current();
    });
    const stopShortcut=installVideoProjectShortcuts(window,{close:()=>void requestClose.current()});
    return()=>{disposed=true;stopShortcut();void subscription.then(stop=>stop()).catch(()=>{});};
  },[]);
  useEffect(()=>{if(reason)dialog.current?.showModal();else dialog.current?.close();},[reason]);
  useEffect(()=>{if(reason==="export"&&!busy)setReason(null);},[reason,busy]);
  const discard=()=>{
    // The window must always remain closable, even when the media file that
    // the editor references has disappeared.
    allowClose.current=true;
    void getCurrentWindow().close().catch(()=>{allowClose.current=false;setReason("save");});
  };
  return <dialog ref={dialog} role="dialog" className="kiri-video-close-dialog"
    aria-hidden={reason===null}
    aria-labelledby="video-close-title" aria-describedby="video-close-detail"
    onCancel={event=>{event.preventDefault();setReason(null);}}
    onKeyDown={event=>event.stopPropagation()}>
    <strong id="video-close-title">{t(reason==="export"?"Export in progress":"Couldn't save your latest changes")}</strong>
    <p id="video-close-detail">{t(reason==="export"
      ?"Cancel the export or wait for it to finish before closing."
      :"Keep this window open to retry saving. Closing now will discard only the changes that have not been saved.")}</p>
    <div>
      <button type="button" autoFocus className="kiri-button kiri-button--secondary" onClick={()=>setReason(null)}>{t("Keep editing")}</button>
      {reason==="save"&&<>
        <button type="button" disabled={retrying} className="kiri-button kiri-button--primary" onClick={()=>void requestClose.current()}>{t(retrying?"Saving edit…":"Retry saving & close")}</button>
        <button type="button" className="kiri-button kiri-button--secondary" onClick={discard}>{t("Discard unsaved changes & close")}</button>
      </>}
    </div>
  </dialog>;
}
