
window.addEventListener("load", () => {
    console.log("start __zig_devserver_api.js");
    window.__zig_devserver_reload_running = false;
    window.__zig_devserver_reload_time = 0;
    window.setInterval(async () => {
        if (window.__zig_devserver_reload_running) return;
        window.__zig_devserver_reload_running = true;
        try {
            const res = await fetch("/__zig_devserver_api", {
                body: JSON.stringify({
                    action: "client_reload_check",
                    start_time: window.__zig_devserver_reload_time,
                }),
                cache: 'no-store',
                method: 'POST',
            });
            const ress = await res.json();
            window.__zig_devserver_reload_running = false;
            if (window.__zig_devserver_reload_time === 0) {
                window.__zig_devserver_reload_time = ress.start_time;
            } else if (window.__zig_devserver_reload_time === ress.start_time) {
                return;
            } else {
                console.error("reload:", window.__zig_devserver_reload_time, ress.start_time);
                window.location.reload();
            }
        } catch (err) {
            console.error(err);
            window.__zig_devserver_reload_running = false;
        }
    }, 500);
});

