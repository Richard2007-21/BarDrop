import asyncio, os, sys
from playwright.async_api import async_playwright
# Bilder des Browser-GIFs: render(t) für jeden Frame, 25 Bilder pro Sekunde
async def main():
    fps=int(sys.argv[1]) if len(sys.argv)>1 else 25
    only=[float(x) for x in sys.argv[2:]]
    async with async_playwright() as p:
        b=await p.chromium.launch(); pg=await b.new_page(viewport={"width":880,"height":550},device_scale_factor=1)
        await pg.goto(f"file://{os.getcwd()}/gif3.html"); await pg.wait_for_timeout(400)
        dur=await pg.evaluate("window.DURATION")
        os.makedirs("frames3",exist_ok=True)
        times=only or [i/fps for i in range(int(round(dur*fps)))]
        for i,t in enumerate(times):
            await pg.evaluate(f"render({t})")
            await pg.screenshot(path=f"frames3/{'t%05.2f'%t if only else 'f%04d'%i}.png")
        await b.close()
asyncio.run(main())
