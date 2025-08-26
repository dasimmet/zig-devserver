
window.addEventListener("load", () => {
    console.log("start __zig_devserver_api.js");
    window.__zig_devserver_ws_url = window.location.href.replace("http://", "ws://").replace("https://", "wss://");
    window.__zig_devserver_reload_time = 0;
    const connect_ws = async () => {

        console.log("connect ws:", window.__zig_devserver_ws_url);
        const socket = new WebSocket(window.__zig_devserver_ws_url);
        window.__zig_devserver_socket = socket;
        socket.onopen = function (e) {
            console.log("__zig_devserver_api.js [open] Connection established");
            socket.send("Hi im a Client!");
        };

        socket.onmessage = function (event) {
            console.log(`__zig_devserver_api.js [message] Data received from server: ${event.data}`);
            const res = JSON.parse(event.data);
            if (window.__zig_devserver_reload_time === 0) {
                window.__zig_devserver_reload_time = res.start_time;
            } else if (window.__zig_devserver_reload_time !== res.start_time) {
                console.error("reload:", window.__zig_devserver_reload_time, res.start_time);
                window.location.reload();
            }
        };

        socket.onclose = function (event) {
            if (event.wasClean) {
                console.log(`__zig_devserver_api.js [close] Connection closed cleanly, code=${event.code} reason=${event.reason}`);
            } else {
                console.error('__zig_devserver_api.js [close] Connection died');
            }
            window.setTimeout(connect_ws, 100);
        };


        socket.onerror = function (error) {
            console.error('__zig_devserver_api.js [error]', error);
        };
    };
    connect_ws();
});

