REM @ECHO off
REM Converted from ecl_nsi.sh

SETLOCAL

SET source=%1
SET where=%2
CD %where%
SET dest=ecl.nsi

type %source%1 | ..\c\cut.exe "@ECLDIR@" "%where%" > %dest%
dir /s /b /a:-d | ..\c\cut.exe "ecl.exe" "/DELETE/" "ecl.nsi" "/DELETE/" "%where%\\" "" > ../aux_files
dir /s /b /a:d | ..\c\cut.exe "ecl.exe" "/DELETE/" "ecl.nsi" "/DELETE/" "%where%\\" "" > ../aux_dirs
echo HOLA
for /f %%i in (../aux_dirs) do @echo %%i
for /f %%i in (../aux_dirs) do @echo File /r "${ECLDIR}\%%i" >> %dest%
for /f %%i in (../aux_files) do @echo File "${ECLDIR}\%%i" >> %dest%
type %source%2 >> %dest%
for /f %%i in (../aux_files) do @echo Delete "$INSTDIR\%%i" >> %dest%
for /f %%i in (../aux_dirs) do @echo RMDir /r "$INSTDIR\%%i" >> %dest%
type %source%3 >> %dest%

ENDLOCAL
