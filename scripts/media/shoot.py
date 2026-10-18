import asyncio, sys
from playwright.async_api import async_playwright
async def main():
    async with async_playwright() as p:
        b = await p.chromium.launch()
        pg = await b.new_page(viewport={"width":1600,"height":1000}, device_scale_factor=2)
        for n in sys.argv[1:]:
            await pg.goto(f"file://{__import__('os').getcwd()}/{n}.html"); await pg.wait_for_timeout(300)
            await pg.screenshot(path=f"{n}.png")
        await b.close()
asyncio.run(main())
