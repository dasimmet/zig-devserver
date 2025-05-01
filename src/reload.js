
window.addEventListener("load", () => {
    console.log("start reload.js");
    window.__zig_devserver_reload_running = false;
    window.setInterval(async () => {
        if (window.__zig_devserver_reload_running) return;
        window.__zig_devserver_reload_running = true;
        try {
            const res = await fetch("/__zig_devserver_api", {
                body: JSON.stringify({
                    action: "client_reload_check",
                }),
                cache: 'no-store',
                method: 'POST',
            });
            const txt = await res.text();
            window.__zig_devserver_reload_running = false;
            if (txt !== 'no') {
                console.error("expected no:", txt);
                window.setTimeout(() => {
                    console.log("reload now");
                    // window.location.reload();
                }, 500);
            }
        } catch (err) {
            console.error(err);
            window.__zig_devserver_reload_running = false;
            window.setTimeout(() => {
                console.log("reload now");
                // window.location.reload();
            }, 500);
        }
    }, 500);
});
