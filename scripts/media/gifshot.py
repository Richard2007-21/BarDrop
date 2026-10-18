import asyncio, os
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b=await p.chromium.launch(); pg=await b.new_page(viewport={"width":880,"height":550},device_scale_factor=1)
        await pg.goto(f"file://{os.getcwd()}/gif.html"); await pg.wait_for_timeout(300)
        os.makedirs("frames",exist_ok=True)
        fps=30; n=int(9.0*fps)
        for i in range(n):
            await pg.evaluate(f"render({i/fps})")
            await pg.screenshot(path=f"frames/f{i:04d}.png")
        await b.close()
asyncio.run(main())
