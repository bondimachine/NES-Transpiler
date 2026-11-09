@echo off
echo ============================================================
echo  NES88 AOT Toolchain: Building All NES ROMs for Intel 8088
echo ============================================================

for %%F in (*.nes) do (
    echo.
    echo --- Processing %%F ---
    node "%~dp0aot_transpiler.js" %%F %1
    if exist %%~nF.asm (
        D:\cc65\bin\nasm.exe -f bin %%~nF.asm -o %%~nF.com
        if exist %%~nF.com (
            echo [SUCCESS] Generated %%~nF.com
        ) else (
            echo [ERROR] NASM failed for %%~nF.asm
        )
    )
)

echo.
echo ============================================================
echo  Build Complete!
echo ============================================================
dir *.com

