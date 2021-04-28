Import-Module "C:\program files\veeam\Console\Veeam.Backup.PowerShell.dll" -DisableNameChecking
#load the veeam powershell module, you might need to change the path

function Get-TimeStamp {
    
    return "[{0:dd/MM/yy} {0:HH:mm:ss}]" -f (Get-Date)

}
function start-restore-test {
    [CmdletBinding()]
    param (
        [Parameter()] [string[]] $nodeNames = "test",
        #array of strings with the names of the nodes to restore
        #we populate this with a puppet query
        [Parameter()] [string] $restoreHost = "restore-host",
        [Parameter()] [string] $restorePath = "restore path",
        [Parameter()] [int] $attempts = 180,  #how many attemts to retry the verification
        [Parameter()] [int] $retrySeconds = 5, #seconds between attemts
        [Parameter()] [PSCredential] $cred = (New-Object System.Management.Automation.PSCredential -ArgumentList "ab2", ("abc" | ConvertTo-SecureString -AsPlainText -Force)) #
        #credentials to try to login to the VMs with
    )

    $succeded = @() # array for nodes that restore correctly
    $failed = @{} # list of nodes that fail restore
    $start = Get-Date  #timestamp for when this script starts
    $message = "Veeam restore verification started at " + (Get-TimeStamp)
    #here you can write this to eventlog if you want
    write-host $message
    #Write-EventLog -LogName "" -Source "" -EventID  -EntryType Information -Message $message

    foreach ($n in $nodenames) { #here you can write this to eventlog if you want
        $timecheck = get-date
        while ((Get-VBRInstantRecovery).count -gt 0) { #check that there isn't a restore going on already, if there is, then wait
            if (((get-date) - $timecheck).minutes -gt 120) { #if we've waited for more than 2 hours, unmount all running instant recoveries
                write-host "waited 2 hours, stopping all instant restores"
                $recovery = Get-VBRInstantRecovery
                foreach ($rec in $recovery) {
                    Stop-VBRInstantRecovery -InstantRecovery $rec
                }
            } else {
                write-host "waiting for restores to stop"
                Start-Sleep 10 
            }
        }

        $restorepoint = Get-VBRRestorePoint -Name $n #check if there are restorepoints for this machine
        $retrycount = 0 #how many times to try to mount a backup
        if ($restorepoint) { #if there is a restorepoint
            while ($retrycount -lt 3) { # if the attempts to try to mount are less than 3
                write-host $n +" : has a restore point" 
                $id = Start-VBREpInstantRecovery -Server $restoreHost -RestorePoint $restorepoint[$restorepoint.Length - 1] -Path $restorePath -PowerUp $true
                #do an instant restore of the restorepoint
                while ((Get-VBRInstantRecovery -Id $id.id).mountstate -eq "Mounting") { Start-Sleep 10 ; write-host "restoring "$n }
                #as long as its working on mounting, just wait
                switch ((Get-VBRInstantRecovery -Id $id.id).mountstate) { #when no longer mounting
                    "Mounted" { #if mounted
                        $count = 0 #attempt counter

                        $session = New-PSSession -ComputerName $restoreHost #create a pssession to the hyper-v host
                        while ($session.state -eq "Broken") { #if that failed, 
                            Get-PSSession | Remove-PSSession #remove the session
                            $session = New-PSSession -ComputerName $restoreHost #and create a new one
                        }

                        $res = Invoke-Command -Session $session -ScriptBlock { #run this scriptblock on the hyper-v host
                       
                            $credential = $Using:cred # pass credentials from parameters
                            
                            $r = @{} #this is a return object
                            
                            while ($count -le $Using:attempts) {  # counting up to max attempts from parameters
                                $count++  #increment counter
                            
                                try { #try to make a remote pssession to the vm from the hyper-v host
                                    New-PSSession -VMName (get-vm).Name -Credential $credential -ErrorAction stop
                                }
                                catch { # look at error
                                    $ErrorMessage = $_.Exception.Message; 
                                    $result = $ErrorMessage
                                    if ($ErrorMessage -eq "The credential is invalid.") { # if error is wrong credentials
                                        write-host "Testing logon to VM: " $ErrorMessage " the authentication services are running and the VM is verified"
                                        $r.add("counter", $count) #return count number
                                        $r.add("result", $result) #and the result
                                        return $r
                                    } else { # or write this
                                        write-host "login testing failed, trying again. error: " $ErrorMessage
                                    }
                                } 
                            
                                # if the authentication attempt failed, try to find a VM heartbeat
                                $result = Get-VMIntegrationService -VMName (get-vm).name -Name Heartbeat
                                if ($result.PrimaryStatusDescription -eq "OK") { #heartbeat found
                                    write-host "heartbeat found. Success"
                                    $r.add("counter", $count)
                                    $r.add("result", "OK")
                                    return $r # return success
                                } else { #if no heartbeat, try authentication and heartbeat again
                                    write-host "no heartbeat found, trying again in $Using:retrySeconds seconds. attempt number: $count"
                                }
                                Start-Sleep -Seconds $Using:retrySeconds #but waif a few seconds before trying
                            }
                            #if it's only failed for all the attempts listed in parameters
                            $r.add("counter", $count) #return counter number
                            $r.add("result", $result) #and last error message
                            return $r
                        }
                        
                        #if authentication or heartbeat succeeded, add the nodename to the succeeded array
                        if ($res["result"] -eq "OK" -or $res["result"] -eq "The credential is invalid.") {
                            $succeded += $n
                        } else { #otherwise add info to the failed array
                            $seconds = $res["counter"] * $retrySeconds
                            write-host $seconds
                            write-host $res["result"]
                            $e = $res["result"] + " tried for: $seconds seconds"
                            write-host $e
                            $failed.add($n, $e)
                        }
                        Remove-PSSession $session #close the pssession
                        $retrycount = 3 # exit the mounting loop
                    }
                    "MountFailed" { #if mounting failed
                        if ($retrycount -eq 2) { # and 3 attempts have been done
                            write-host "mounting failed for 3 attempts"
                            $failed.add($n, "MountFailed") #add node as failed
                            $retrycount += 1 #exit mounting loop
                        } else {
                            write-host "mounting failed, trying again"
                            Get-VBRInstantRecovery -Id $id.id | Stop-VBRInstantRecovery #close the instant recovery
                            $retrycount += 1 #increment the mounting attempt counter
                        }
                    }
                }
            }
            Write-Host "shutting down the instant restore of "$n 
            Get-VBRInstantRecovery -Id $id.id | Stop-VBRInstantRecovery #close instant recovery
            $recovery = Get-VBRInstantRecovery # if there are more instant recoveries going on
            foreach ($rec in $recovery) { #check all instant recoveries
                if ($rec.vmname -eq $n) { #if there are more of $n, 
                    Stop-VBRInstantRecovery -InstantRecovery $rec #close them
                }
            }

        }
        else {
            write-host $n ": no restorepoint" #the machine doesn't have a restore point
        }
    }

    if ($succeded.count -gt 0) { #if there are more than 0 in the succeeded array
        $message = "Backups verified for the following servers:  `r`n"
        foreach ($s in $succeded) {
            $message += $s + "`r`n"
        } 
        #here you can choose to write to eventlog or screen or something
        write-host $message
        #Write-EventLog -LogName "" -Source "" -EventID  -EntryType Information -Message $message
    }
    if ($failed.count -gt 0) {
        $message = "Backup verification failed for the following servers: `r`n"
        foreach ($f in $failed.keys) {
            $message += $f + " : " + $failed[$f] + "`r`n"
        } 
        #here you can choose to write to eventlog or screen or something
        write-host $message
        #Write-EventLog -LogName "" -Source "" -EventID  -EntryType Error -Message $message
    }
    $stop = Get-Date
    $message = "Veeam restore verification has finished at " + (get-timestamp) + ". It ran for " + (($stop - $start).TotalHours) + " hours."
    #here you can choose to write to eventlog or screen or something
    write-host $message
    #Write-EventLog -LogName "" -Source "" -EventID  -EntryType Information -Message $message
}
