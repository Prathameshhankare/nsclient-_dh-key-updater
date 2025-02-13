# Define log file
$logFilePath = "PATH/TO/YOUR/LOGFILE.log"

# Define the CSV file path
$outputCsv = "PATH/TO/YOUR/output.csv"

# Ensure headers are added to the CSV if it doesn't exist
if (-not (Test-Path $outputCsv)) {
    "Date,Time,Server,Server Status,NSClient++ Service,DH Key Created?,Config file updated,Restarted NSClient++?" | Out-File -FilePath $outputCsv -Encoding UTF8
}

# Function to log messages to both console and file
function Log-Message {
    param (
        [string]$message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "$timestamp - $message"

    # Write the message to the console
    Write-Output $logMessage

    # Append the message to the log file
    Add-Content -Path $logFilePath -Value $logMessage
}

# Get the list of domain controllers
$domainControllers = Get-ADDomainController -Filter *

foreach ($dc in $domainControllers) {
    $server = $dc.HostName
    Log-Message "Processing $server"

    # Initialize CSV columns
    $currentDate = Get-Date -Format "yyyy-MM-dd"
    $currentTime = Get-Date -Format "HH:mm:ss"
    $serverStatus = ""
    $nsclientService = "No"
    $dhKeyCreated = "No"
    $configUpdated = "No"
    $serviceRestarted = "No"

    # Add the date, time, and server name to the CSV
    $currentCsvLine = "$currentDate,$currentTime,$server,"
	
    # Check if the server is up
    if (Test-Connection -ComputerName $server -Count 1 -Quiet) {
        Log-Message "$server is up."
        $serverStatus = "UP"
    } else {
        Log-Message "$server is down or unreachable."
        $serverStatus = "Down"

        # Append the server status to the CSV and skip further steps for this server
        "$currentCsvLine$serverStatus,NA,NA,NA,NA" | Out-File -FilePath $outputCsv -Append -Encoding UTF8
        continue
    }

    # Check if the DH key file already exists
    $remotePath = "\\$server\C$\Program Files\NSClient++\security\nrpe_dh_2048.pem"
    $fileExists = Test-Path -Path $remotePath
    if ($fileExists) {
        Log-Message "DH key file already exists on $server. Skipping..."
        $dhKeyCreated = "Already Exists"

        # Append the server status and DH key status to the CSV
        "$currentCsvLine$serverStatus,Yes,$dhKeyCreated,NA,NA" | Out-File -FilePath $outputCsv -Append -Encoding UTF8
        continue
    }

    # Check if the NSClient++ service is present
    $service = Get-Service -ComputerName $server -Name "nscp" -ErrorAction SilentlyContinue
    if ($service) {
        Log-Message "NSClient++ service found on $server."
        $nsclientService = "Yes"

        # Define the DH parameters
        $dhParams = @"
-----BEGIN DH PARAMETERS-----
MIIBCAKCAQEA/qOUktvvXrdUIef1MahNnc03ZxLqHOQulmWNgFVcz/x1Rx3UB4Td
aXAYkTWbXGRKg3MF+FGIhZIuv9MK4V7BsAiGzoH9aWEPSphllazioTYYeeZyzDmk
QfPZHO/GPFw7fz1zPd7isXo3nXSpsMf9P8ybuSGE/KoVwuXAEfhVbpVrcHq+U4gy
tPqjPXtTAwzfMMDpp7L2zi+Baqb78EjGJVQ3WGXscT34XyLWRpas7ai8vCSpGxMP
xyHdap4mN0BZ7J4RnRv9y1nA+xbWCNyDKH/q2UT/c+iK5UFG2JdgjxVs/wlI1gle
c4w0X5vt8igXCaxr8qncJQ5sswEKPDFAfwIBAg==
-----END DH PARAMETERS-----
"@

        # Create the DH key file
        Invoke-Command -ComputerName $server -ScriptBlock {
            param ($remotePath, $dhParams)
            New-Item -Path $remotePath -ItemType File -Force
            Set-Content -Path $remotePath -Value $dhParams
        } -ArgumentList $remotePath, $dhParams

        Log-Message "DH key file created on $server at $remotePath."
        $dhKeyCreated = "Yes"

        # *** Define the path to the nsclient.ini file on the remote server ***
        $remoteIniPath = "C:\Program Files\NSClient++\nsclient.ini"

        # Update the nsclient.ini file
        Invoke-Command -ComputerName $server -ScriptBlock {
            param ($remoteIniPath)
            $iniContent = Get-Content -Path $remoteIniPath

            # Check if the [/settings/NRPE/server] section exists
            $sectionExists = $false
            for ($i = 0; $i -lt $iniContent.Length; $i++) {
                if ($iniContent[$i] -match '\[/settings/NRPE/server\]') {
                    $sectionExists = $true
                    if ($iniContent[$i + 1] -notmatch 'dh = `${certificate-path}`/nrpe_dh_2048.pem') {
                        $iniContent = $iniContent[0..$i] + "`ndh = `${certificate-path}`/nrpe_dh_2048.pem" + $iniContent[($i + 1)..($iniContent.Length - 1)]
                    }
                    break
                }
            }

            if (-not $sectionExists) {
                # Add the [/settings/NRPE/server] section with the dh line at the end of the file
                $iniContent += "`n[/settings/NRPE/server]`n`ndh = `${certificate-path}`/nrpe_dh_2048.pem"
            }

            # Write the updated content back to the file
            Set-Content -Path $remoteIniPath -Value $iniContent
        } -ArgumentList $remoteIniPath

        Log-Message "nsclient.ini file updated on $server."
        $configUpdated = "Yes"

        # Restart the NSClient++ service
        Invoke-Command -ComputerName $server -ScriptBlock {
            Restart-Service -Name "nscp"
        }

        Log-Message "NSClient++ service restarted on $server."
        $serviceRestarted = "Yes"
    } else {
        Log-Message "NSClient++ service not found on $server."
        $nsclientService = "No"
    }

    # Append all the details for this server to the CSV
    "$currentCsvLine$serverStatus,$nsclientService,$dhKeyCreated,$configUpdated,$serviceRestarted" | Out-File -FilePath $outputCsv -Append -Encoding UTF8
}
