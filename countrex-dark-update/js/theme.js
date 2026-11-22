/* Countrex theme: add <script src="js/theme.js"></script> inside <head> of any page to make it follow Settings > Appearance. */
(function(){try{
  var l=document.createElement("link");l.rel="stylesheet";l.href="css/dark.css";document.head.appendChild(l);
  var t=(JSON.parse(localStorage.getItem("countrex_settings")||"{}").theme)||"light";
  if(t==="system")t=matchMedia("(prefers-color-scheme:dark)").matches?"dark":"light";
  if(t==="dark")document.documentElement.setAttribute("data-theme","dark");
}catch(e){}})();
