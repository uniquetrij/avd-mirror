// wgccap - Windows.Graphics.Capture helper for the emulator mirror.
// Captures the emulator window even when it is occluded, at full frame rate,
// host-side (FLAG_SECURE is irrelevant to the host compositor).
//
// Serves:
//   GET /frame.jpg  -> latest JPEG frame (CORS-enabled, for the mirror page)
//   GET /status     -> fps/size/age text
//   GET /health     -> "ok"
//
// Args: --hwnd 0x1234 | --proc qemu-system-x86_64   --port 8778   --gsize 1080x2280
//
// Frames are cropped to the window *client* area (the guest display): the raw
// window capture also contains the title bar, which would shift every mirrored
// touch upward. Crop geometry is read per frame, so resizing the emulator window
// keeps the mirror pixel-exact.

using System.Diagnostics;
using System.Net;
using System.Runtime.InteropServices;
using System.Runtime.InteropServices.WindowsRuntime;
using Windows.Graphics.Capture;
using Windows.Graphics.DirectX;
using Windows.Graphics.Imaging;

internal static class Program
{
    // --- window interop -------------------------------------------------
    // Called directly through the vtable: Marshal.QueryInterface succeeds but
    // RCW casting is unreliable for this factory interface on .NET 8.
    [UnmanagedFunctionPointer(CallingConvention.StdCall)]
    delegate int CreateForWindowD(IntPtr thisPtr, IntPtr window, ref Guid riid, out IntPtr item);

    // (IGraphicsCaptureItemInterop = 3628E81B-3CAC-4C60-B7F4-23CE0E0C3356)

    [DllImport("combase.dll", CharSet = CharSet.Unicode)]
    static extern int WindowsCreateString(string sourceString, int length, out IntPtr hstring);
    [DllImport("combase.dll")]
    static extern int WindowsDeleteString(IntPtr hstring);
    [DllImport("combase.dll")]
    static extern int RoGetActivationFactory(IntPtr classId, ref Guid riid, out IntPtr factory);

    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct POINT { public int X, Y; }

    // WGC reports window sizes in physical pixels; without DPI awareness this
    // process would measure the window in virtualised pixels and the crop would
    // be scaled down by the monitor's DPI factor.
    [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool GetClientRect(IntPtr hWnd, out RECT r);
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr hWnd, ref POINT p);

    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr hWnd);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] static extern int GetSystemMetrics(int index);
    [DllImport("user32.dll")]
    static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);

    const uint SWP_NOZORDER = 0x0004, SWP_NOACTIVATE = 0x0010;
    const int SW_SHOWNOACTIVATE = 8, SW_RESTORE = 9;
    const int SM_XVIRTUALSCREEN = 76, SM_YVIRTUALSCREEN = 77,
              SM_CXVIRTUALSCREEN = 78, SM_CYVIRTUALSCREEN = 79;

    static IntPtr FindWindowByProc(string procName)
    {
        foreach (var p in Process.GetProcessesByName(procName))
            if (p.MainWindowHandle != IntPtr.Zero) return p.MainWindowHandle;
        return IntPtr.Zero;
    }

    static Guid ItemIid()
    {
        // IID_IGraphicsCaptureItem (windows.graphics.capture.idl). MUST be a literal:
        // typeof(GraphicsCaptureItem).GUID is the CsWinRT synthesized signature GUID
        // (cc7b16ab-...) and CreateForWindow rejects it with E_NOINTERFACE.
        return new Guid("79C3F95B-31F7-4EC2-A464-632EF5D30760");
    }

    static Exception Fail(string step, int hr)
        => new COMException($"{step} failed hr=0x{hr:X8}", hr);

    static GraphicsCaptureItem CreateItemForWindow(IntPtr hwnd)
    {
        Guid iidFactory = new("00000035-0000-0000-C000-000000000046"); // IActivationFactory
        const string cls = "Windows.Graphics.Capture.GraphicsCaptureItem";
        IntPtr hstr = IntPtr.Zero, factory = IntPtr.Zero, interopPtr = IntPtr.Zero;
        try
        {
            int hr = WindowsCreateString(cls, cls.Length, out hstr);
            if (hr != 0) throw Fail("WindowsCreateString", hr);
            hr = RoGetActivationFactory(hstr, ref iidFactory, out factory);
            if (hr != 0) throw Fail("RoGetActivationFactory", hr);

            Guid iidInterop = new("3628E81B-3CAC-4C60-B7F4-23CE0E0C3356");
            hr = Marshal.QueryInterface(factory, ref iidInterop, out interopPtr);
            if (hr != 0) throw Fail("QI IGraphicsCaptureItemInterop", hr);

            // vtable: [0]=QueryInterface [1]=AddRef [2]=Release [3]=CreateForWindow
            IntPtr vtbl = Marshal.ReadIntPtr(interopPtr);
            IntPtr fnPtr = Marshal.ReadIntPtr(vtbl, 3 * IntPtr.Size);
            var createForWindow = Marshal.GetDelegateForFunctionPointer<CreateForWindowD>(fnPtr);
            Guid iid = ItemIid();
            hr = createForWindow(interopPtr, hwnd, ref iid, out IntPtr ptr);
            if (hr != 0) throw Fail($"CreateForWindow(iid={iid})", hr);
            Console.WriteLine($"item ptr=0x{ptr.ToInt64():x} iid={iid}");
            try { return GraphicsCaptureItem.FromAbi(ptr); }
            finally { Marshal.Release(ptr); }
        }
        finally
        {
            if (interopPtr != IntPtr.Zero) Marshal.Release(interopPtr);
            if (factory != IntPtr.Zero) Marshal.Release(factory);
            if (hstr != IntPtr.Zero) WindowsDeleteString(hstr);
        }
    }

    // --- minimized windows produce no WGC frames: quietly restore them and park
    // them just outside the virtual screen. Dropping the window to HWND_BOTTOM
    // (the previous behaviour) only put it behind the editor, so an emulator
    // minimized to get it out of the way came back into view on the next rescue.
    // Off-screen keeps it out of sight *and* captured: a window that is merely
    // positioned outside the virtual screen still has a DWM surface, while a
    // hidden (SW_HIDE) or minimized one has none and the mirror freezes.
    static RECT _stash; static bool _haveStash;

    static bool OffScreen(RECT r)
    {
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN), vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);
        return r.R <= vx || r.L >= vx + vw || r.B <= vy || r.T >= vy + vh;
    }

    static void RescueIfMinimized(IntPtr hwnd)
    {
        bool minimized = IsIconic(hwnd);
        if (minimized)
        {
            ShowWindow(hwnd, SW_SHOWNOACTIVATE);
            if (IsIconic(hwnd))
            {
                IntPtr prev = GetForegroundWindow();
                ShowWindow(hwnd, SW_RESTORE);
                if (prev != IntPtr.Zero && prev != hwnd) SetForegroundWindow(prev);
            }
            if (IsIconic(hwnd)) return; // stuck; retry next tick
        }

        RECT r;
        if (!GetWindowRect(hwnd, out r)) return;
        bool off = OffScreen(r);

        if (!minimized)
        {
            // Remember where the window really is, so a parked one that the user
            // brings to the front (taskbar click / Alt-Tab) can be put back: it
            // would otherwise come forward while still outside the desktop, which
            // makes the click look like it did nothing.
            if (!off) { _stash = r; _haveStash = true; return; }
            if (_haveStash && GetForegroundWindow() == hwnd)
                SetWindowPos(hwnd, IntPtr.Zero, _stash.L, _stash.T,
                             _stash.R - _stash.L, _stash.B - _stash.T,
                             SWP_NOZORDER | SWP_NOACTIVATE);
            return;
        }

        int w = r.R - r.L, h = r.B - r.T;
        if (w <= 0 || h <= 0) return;
        if (!off) { _stash = r; _haveStash = true; }      // remember only a real position
        int vx = GetSystemMetrics(SM_XVIRTUALSCREEN), vy = GetSystemMetrics(SM_YVIRTUALSCREEN);
        int vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);
        SetWindowPos(hwnd, IntPtr.Zero, vx + vw + 100, vy + 200, w, h,
                     SWP_NOZORDER | SWP_NOACTIVATE);
    }

    // --- state ------------------------------------------------------------
    static readonly object FrameLock = new();
    static readonly object CapGate = new();
    static byte[] _jpeg = Array.Empty<byte>();
    static long _frameTicks;
    static long _frameCount;
    static int _width, _height;
    static IntPtr _hwnd;                       // window being captured (for crop geometry)
    static int _guestW, _guestH;              // 0 => crop to the whole client area
    static readonly Queue<long> Recent = new();
    static volatile bool _running = true;

    static int Main(string[] args)
    {
        // Must run before any window/DC is touched, otherwise GetWindowRect and
        // GetClientRect are DPI-virtualised and disagree with WGC's frame size.
        try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch { }

        IntPtr hwnd = IntPtr.Zero;
        int port = 8778;
        string proc = "qemu-system-x86_64";

        for (int i = 0; i < args.Length - 1; i++)
        {
            switch (args[i])
            {
                case "--hwnd": hwnd = new IntPtr(Convert.ToInt64(args[i + 1], 16)); break;
                case "--port": port = int.Parse(args[i + 1]); break;
                case "--proc": proc = args[i + 1]; break;
                case "--gsize":
                    var m = System.Text.RegularExpressions.Regex.Match(args[i + 1], @"^(\d+)x(\d+)$");
                    if (m.Success)
                    {
                        _guestW = int.Parse(m.Groups[1].Value);
                        _guestH = int.Parse(m.Groups[2].Value);
                    }
                    break;
            }
        }
        if (hwnd == IntPtr.Zero) hwnd = FindWindowByProc(proc);
        if (hwnd == IntPtr.Zero)
        {
            Console.Error.WriteLine($"window not found for process '{proc}'");
            return 2;
        }

        try { RunCapture(hwnd, port); }
        catch (Exception ex)
        {
            Console.Error.WriteLine("capture failed: " + ex);
            return 1;
        }
        return 0;
    }

    static void RunCapture(IntPtr hwnd, int port)
    {
        _hwnd = hwnd;
        var item = CreateItemForWindow(hwnd);
        item.Closed += (_, __) => { _running = false; };

        using var d3d = new D3DDevice();
        var size = item.Size;
        _width = size.Width; _height = size.Height;
        int poolW = size.Width, poolH = size.Height;

        using var framePool = Direct3D11CaptureFramePool.CreateFreeThreaded(
            d3d.Device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, size);

        framePool.FrameArrived += (pool, _) =>
        {
                    // This callback must never block. It used to hold CapGate across a
                    // blocking SoftwareBitmap copy (GetAwaiter().GetResult()), and since
                    // the pool is FreeThreaded a burst parks several thread-pool threads
                    // waiting on continuations that need those same threads -- the pool
                    // starves and capture stops for good, leaving a mirror frozen on one
                    // frame. So: drain here (a pooled surface that is not retrieved stops
                    // WGC delivering), hand the newest frame to a dedicated thread, and
                    // return immediately.
                    var newest = default(Direct3D11CaptureFrame);
                    try
                    {
                        while (true)
                        {
                            var f = pool.TryGetNextFrame();
                            if (f == null) break;
                            newest?.Dispose();
                            newest = f;
                        }
                        if (newest != null)
                        {
                            var stale = Interlocked.Exchange(ref _slotFrame, newest);
                            stale?.Dispose();       // superseded before it was ever copied
                            newest = null;
                            _pipeSignal.Set();
                        }
                    }
                    catch (Exception ex)
                    {
                        newest?.Dispose();
                        Console.Error.WriteLine("frame error: " + ex.Message);
                    }
        };

        using var session = framePool.CreateCaptureSession(item);
        TrySet(session, "IsBorderRequired", false);        // no yellow border
        TrySet(session, "IsCursorCaptureEnabled", false);  // no cursor in mirror
        session.StartCapture();
        StartPipeline();

        var listener = new HttpListener();
        listener.Prefixes.Add($"http://127.0.0.1:{port}/");
        listener.Start();
        _ = Task.Run(() => Serve(listener));
        Console.WriteLine($"wgccap ready hwnd=0x{hwnd.ToInt64():x} {size.Width}x{size.Height} port={port}");

        while (_running && IsWindow(hwnd))
        {
            Thread.Sleep(250);
            RescueIfMinimized(hwnd);

            // A WGC frame pool is fixed at creation: after the user resizes the
            // emulator window it keeps returning stale-sized frames. Recreate it
            // so the mirror keeps matching the guest pixel grid.
            var cur = item.Size;
            if (cur.Width > 0 && cur.Height > 0 && (cur.Width != poolW || cur.Height != poolH))
            {
                try
                {
                    lock (CapGate)
                    {
                        framePool.Recreate(d3d.Device, DirectXPixelFormat.B8G8R8A8UIntNormalized, 2, cur);
                        poolW = cur.Width; poolH = cur.Height;
                        _width = cur.Width; _height = cur.Height;
                    }
                    Console.WriteLine($"wgccap resized to {cur.Width}x{cur.Height}");
                }
                catch (Exception ex) { Console.Error.WriteLine("recreate failed: " + ex.Message); }
            }
        }
        Console.Error.WriteLine("window gone, exiting");
        _running = false;
        listener.Stop();
    }

    static void TrySet(object obj, string prop, object val)
    {
        try
        {
            var p = obj.GetType().GetProperty(prop);
            if (p != null && p.CanWrite) p.SetValue(obj, val);
        }
        catch { /* API not present on this Windows version */ }
    }

    // One dedicated thread owns every expensive step -- GPU copy, crop, JPEG
        // encode -- so the capture callback above never blocks and no thread-pool
        // thread is held hostage. It is a one-deep pipeline: when frames arrive
        // faster than an encode takes, the newest frame simply replaces the one
        // waiting, because encoding a superseded frame would only make the mirror
        // show something older than it already has.
        static Direct3D11CaptureFrame _slotFrame;
        static readonly AutoResetEvent _pipeSignal = new AutoResetEvent(false);

        static void StartPipeline()
        {
            var t = new Thread(PipelineLoop) { IsBackground = true, Name = "wgccap-pipe" };
            t.Start();
        }

        static void PipelineLoop()
        {
            while (_running)
            {
                Direct3D11CaptureFrame f = null;
                // Wait first so a frame is already in hand when the loop comes round.
                if (Volatile.Read(ref _slotFrame) == null) _pipeSignal.WaitOne(200);
                f = Interlocked.Exchange(ref _slotFrame, null);
                if (f == null) continue;
                try
                {
                    // Coalesce: if another frame landed while we were waking up, this
                    // one is already superseded, so skip it rather than pay for it.
                    if (Volatile.Read(ref _slotFrame) != null) { f.Dispose(); continue; }
                    var bmp = SoftwareBitmap.CreateCopyFromSurfaceAsync(f.Surface)
                        .AsTask().GetAwaiter().GetResult();
                    try { Publish(bmp); }
                    finally { bmp.Dispose(); }
                }
                catch (Exception ex) { Console.Error.WriteLine("copy error: " + ex.Message); }
                finally { f.Dispose(); }
            }
        }

        static void Publish(SoftwareBitmap bmp)
        {
            BitmapBounds crop;
            bool cropped = ComputeCrop(_hwnd, bmp.PixelWidth, bmp.PixelHeight, out crop);
            byte[] jpeg = EncodeJpeg(bmp, cropped ? crop : (BitmapBounds?)null);
            lock (FrameLock)
            {
                _jpeg = jpeg;
                _frameTicks = Environment.TickCount64;
                _frameCount++;
                _width = cropped ? (int)crop.Width : bmp.PixelWidth;
                _height = cropped ? (int)crop.Height : bmp.PixelHeight;
                Recent.Enqueue(_frameTicks);
                while (Recent.Count > 120) Recent.Dequeue();
            }
        }

    // Guest display inside the captured window frame. WGC returns the window
    // including its title bar, so the client rect (which is exactly the guest
    // display) is located from the window geometry instead of guessed.
    static bool ComputeCrop(IntPtr hwnd, int frameW, int frameH, out BitmapBounds b)
    {
        b = new BitmapBounds { X = 0, Y = 0, Width = (uint)frameW, Height = (uint)frameH };
        RECT wr, cr;
        if (!GetWindowRect(hwnd, out wr)) return false;
        if (!GetClientRect(hwnd, out cr)) return false;
        var origin = new POINT { X = 0, Y = 0 };
        if (!ClientToScreen(hwnd, ref origin)) return false;

        int cw = cr.R - cr.L, ch = cr.B - cr.T;
        if (cw <= 0 || ch <= 0) return false;

        int dw = cw, dh = ch, ox = 0, oy = 0;
        if (_guestW > 0 && _guestH > 0)
        {
            double s = Math.Min((double)cw / _guestW, (double)ch / _guestH);
            dw = (int)Math.Round(_guestW * s);
            dh = (int)Math.Round(_guestH * s);
            ox = (cw - dw) / 2;
            oy = (ch - dh) / 2;
        }

        int x = Math.Max(0, (frameW - cw) / 2) + ox;
        int y = Math.Max(0, origin.Y - wr.T) + oy;
        int w = dw, h = dh;
        if (x + w > frameW) w = frameW - x;
        if (y + h > frameH) h = frameH - y;
        if (w <= 8 || h <= 8) return false;
        b = new BitmapBounds { X = (uint)x, Y = (uint)y, Width = (uint)w, Height = (uint)h };
        return true;
    }

    static byte[] EncodeJpeg(SoftwareBitmap bmp, BitmapBounds? crop)
    {
        using var stream = new Windows.Storage.Streams.InMemoryRandomAccessStream();
        var enc = BitmapEncoder.CreateAsync(BitmapEncoder.JpegEncoderId, stream)
                              .AsTask().GetAwaiter().GetResult();
        if (crop.HasValue) enc.BitmapTransform.Bounds = crop.Value;
        enc.SetSoftwareBitmap(bmp);
        enc.FlushAsync().AsTask().GetAwaiter().GetResult();
        stream.Seek(0);
        var bytes = new byte[stream.Size];
        using var dr = new Windows.Storage.Streams.DataReader(stream);
        dr.LoadAsync((uint)stream.Size).AsTask().GetAwaiter().GetResult();
        dr.ReadBytes(bytes);
        return bytes;
    }

    static void Serve(HttpListener listener)
    {
        while (_running)
        {
            HttpListenerContext ctx;
            try { ctx = listener.GetContext(); }
            catch { return; }
            _ = Task.Run(() =>
            {
                try { Route(ctx); } catch { /* client disconnected */ }
            });
        }
    }

    static void Route(HttpListenerContext ctx)
    {
        var path = ctx.Request.Url!.AbsolutePath;
        ctx.Response.Headers["Access-Control-Allow-Origin"] = "*";
        ctx.Response.Headers["Cache-Control"] = "no-store";
        // A cross-origin client can only read a response header if it is
        // explicitly exposed, so the frame token has to be exposed too.
        ctx.Response.Headers["Access-Control-Expose-Headers"] = "X-Frame-Seq";
        switch (path)
        {
            case "/health":
                Write(ctx, 200, "text/plain", "ok"u8.ToArray());
                break;
            case "/frame.jpg":
                byte[] jpeg; long seq;
                lock (FrameLock) { jpeg = _jpeg; seq = _frameCount; }
                if (jpeg.Length == 0) Write(ctx, 503, "text/plain", "warming up"u8.ToArray());
                else
                {
                    // The client polls in a tight loop to keep latency low, which
                    // means it asks far more often than the screen changes. The
                    // frame sequence number doubles as a validator, so an
                    // unchanged frame costs a 304 with no body instead of a
                    // re-download and re-decode of an identical image.
                    //
                    // The validator travels as a query parameter rather than an
                    // If-None-Match header on purpose: a custom request header
                    // makes this a CORS preflighted request, which would add a
                    // second round trip to every single poll.
                    var tag = "\"" + seq.ToString() + "\"";
                    bool fresh = ctx.Request.QueryString["since"] == seq.ToString();
                    if (fresh)
                    {
                        ctx.Response.StatusCode = 304;
                        ctx.Response.Headers["X-Frame-Seq"] = tag;
                        ctx.Response.Close();
                    }
                    else
                    {
                        ctx.Response.StatusCode = 200;
                        ctx.Response.ContentType = "image/jpeg";
                        ctx.Response.Headers["X-Frame-Seq"] = tag;
                        ctx.Response.ContentLength64 = jpeg.Length;
                        ctx.Response.OutputStream.Write(jpeg, 0, jpeg.Length);
                        ctx.Response.Close();
                    }
                }
                break;
            case "/status":
                long now = Environment.TickCount64;
                long count, ticks; int w, h; double fps = 0;
                lock (FrameLock)
                {
                    count = _frameCount; ticks = _frameTicks; w = _width; h = _height;
                    if (Recent.Count > 1)
                    {
                        long span = Recent.Last() - Recent.First();
                        if (span > 0) fps = (Recent.Count - 1) * 1000.0 / span;
                    }
                }
                Write(ctx, 200, "text/plain",
                    System.Text.Encoding.ASCII.GetBytes(
                        $"fps={fps:F1} frames={count} size={w}x{h} age={now - ticks}ms"));
                break;
            default:
                Write(ctx, 404, "text/plain", "not found"u8.ToArray());
                break;
        }
    }

    static void Write(HttpListenerContext ctx, int code, string ctype, byte[] body)
    {
        ctx.Response.StatusCode = code;
        ctx.Response.ContentType = ctype;
        ctx.Response.ContentLength64 = body.Length;
        ctx.Response.OutputStream.Write(body, 0, body.Length);
        ctx.Response.Close();
    }
}

// Minimal D3D11 device wrapped as a WinRT IDirect3DDevice (no NuGet deps).
internal sealed class D3DDevice : IDisposable
{
    public Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice Device { get; }

    [DllImport("d3d11.dll", EntryPoint = "D3D11CreateDevice")]
    static extern int D3D11CreateDevice(
        IntPtr adapter, int driverType, IntPtr software, uint flags,
        IntPtr featureLevels, uint featureLevelCount, uint sdkVersion,
        out IntPtr device, out IntPtr featureLevel, out IntPtr context);

    [DllImport("d3d11.dll", EntryPoint = "CreateDirect3D11DeviceFromDXGIDevice")]
    static extern int CreateDirect3D11DeviceFromDXGIDevice(IntPtr dxgiDevice, out IntPtr graphicsDevice);

    IntPtr _d3d11, _context, _inspectable;

    public D3DDevice()
    {
        // D3D_DRIVER_TYPE_HARDWARE=1, D3D11_CREATE_DEVICE_BGRA_SUPPORT=0x80
        int hr = D3D11CreateDevice(IntPtr.Zero, 1, IntPtr.Zero, 0x80,
            IntPtr.Zero, 0, 7 /* D3D 11.0 */, out _d3d11, out _, out _context);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);

        Guid iidDxgi = new("54ec77fa-1377-44e6-8c32-88fd5f44c84c"); // IDXGIDevice (dxgi.idl)
        hr = Marshal.QueryInterface(_d3d11, ref iidDxgi, out IntPtr dxgi);
        if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        try
        {
            hr = CreateDirect3D11DeviceFromDXGIDevice(dxgi, out _inspectable);
            if (hr != 0) Marshal.ThrowExceptionForHR(hr);
        }
        finally { Marshal.Release(dxgi); }

        object o = WinRT.MarshalInspectable<object>.FromAbi(_inspectable);
        Device = o as Windows.Graphics.DirectX.Direct3D11.IDirect3DDevice
                 ?? throw new InvalidOperationException("IDirect3DDevice cast failed");
    }

    public void Dispose()
    {
        if (_inspectable != IntPtr.Zero) { Marshal.Release(_inspectable); _inspectable = IntPtr.Zero; }
        if (_context != IntPtr.Zero) { Marshal.Release(_context); _context = IntPtr.Zero; }
        if (_d3d11 != IntPtr.Zero) { Marshal.Release(_d3d11); _d3d11 = IntPtr.Zero; }
    }
}
