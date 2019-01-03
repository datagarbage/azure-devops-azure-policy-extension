
function Initialize-AzureSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        $Endpoint,
        [Parameter(Mandatory=$false)]
        [string]$StorageAccount)

    #Set UserAgent for Azure Calls
    Set-UserAgent
    
    # Clear context only for Azure RM
    if ($Endpoint.Auth.Scheme -eq 'ServicePrincipal' -and !$script:azureModule -and (Get-Command -Name "Clear-AzureRmContext" -ErrorAction "SilentlyContinue")) {
        Write-Host "##[command]Clear-AzureRmContext -Scope Process"
        $null = Clear-AzureRmContext -Scope Process
        Write-Host "##[command]Clear-AzureRmContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue"
        $null = Clear-AzureRmContext -Scope CurrentUser -Force -ErrorAction SilentlyContinue
    }

    $environmentName = "AzureCloud"
    if($Endpoint.Data.Environment) {
        $environmentName = $Endpoint.Data.Environment
        if($environmentName -eq "AzureStack")
        {
            Add-AzureStackAzureRmEnvironment -endpoint $Endpoint -name "AzureStack"
        }
    }
    
    $scopeLevel = "Subscription"
    
    If ($Endpoint.PSObject.Properties['Data'])
    {
        If ($Endpoint.Data.PSObject.Properties['scopeLevel'])
        {
            $scopeLevel = $Endpoint.Data.scopeLevel
        }
    }

    if ($Endpoint.Auth.Scheme -eq 'Certificate') {
        # Certificate is only supported for the Azure module.
        if (!$script:azureModule) {
            throw (Get-VstsLocString -Key AZ_CertificateAuthNotSupported)
        }

        # Add the certificate to the cert store.
        $certificate = Add-Certificate -Endpoint $Endpoint

        # Setup the additional parameters.
        $additional = @{ }
        if ($StorageAccount) {
            $additional['CurrentStorageAccountName'] = $StorageAccount
        }

        # Set the subscription.
        Write-Host "##[command]Set-AzureSubscription -SubscriptionName $($Endpoint.Data.SubscriptionName) -SubscriptionId $($Endpoint.Data.SubscriptionId) -Certificate ******** -Environment $environmentName $(Format-Splat $additional)"
        Set-AzureSubscription -SubscriptionName $Endpoint.Data.SubscriptionName -SubscriptionId $Endpoint.Data.SubscriptionId -Certificate $certificate -Environment $environmentName @additional
        Set-CurrentAzureSubscription -SubscriptionId $Endpoint.Data.SubscriptionId -StorageAccount $StorageAccount
    } elseif ($Endpoint.Auth.Scheme -eq 'UserNamePassword') {
        $psCredential = New-Object System.Management.Automation.PSCredential(
            $Endpoint.Auth.Parameters.UserName,
            (ConvertTo-SecureString $Endpoint.Auth.Parameters.Password -AsPlainText -Force))

        # Add account (Azure).
        if ($script:azureModule) {
            try {
                Write-Host "##[command]Add-AzureAccount -Credential $psCredential"
                $null = Add-AzureAccount -Credential $psCredential
            } catch {
                # Provide an additional, custom, credentials-related error message.
                Write-VstsTaskError -Message $_.Exception.Message
                Assert-TlsError -exception $_.Exception
                throw (New-Object System.Exception((Get-VstsLocString -Key AZ_CredentialsError), $_.Exception))
            }
        }

        # Add account (AzureRM).
        if ($script:azureRMProfileModule) {
            try {
                if (Get-Command -Name "Add-AzureRmAccount" -ErrorAction "SilentlyContinue") {
                    Write-Host "##[command] Add-AzureRMAccount -Credential $psCredential"
                    $null = Add-AzureRMAccount -Credential $psCredential
                } else {
                    Write-Host "##[command] Connect-AzureRMAccount -Credential $psCredential"
                    $null = Connect-AzureRMAccount -Credential $psCredential
                }
            } catch {
                # Provide an additional, custom, credentials-related error message.
                Write-VstsTaskError -Message $_.Exception.Message
                Assert-TlsError -exception $_.Exception
                throw (New-Object System.Exception((Get-VstsLocString -Key AZ_CredentialsError), $_.Exception))
            }
        }

        # Select subscription (Azure).
        if ($script:azureModule) {
            Set-CurrentAzureSubscription -SubscriptionId $Endpoint.Data.SubscriptionId -StorageAccount $StorageAccount
        }

        # Select subscription (AzureRM).
        if ($script:azureRMProfileModule) {
            Set-CurrentAzureRMSubscription -SubscriptionId $Endpoint.Data.SubscriptionId
        }
    } 
    elseif ($Endpoint.Auth.Scheme -eq 'ServicePrincipal') {
        
        if ($Endpoint.Auth.Parameters.AuthenticationType -eq 'SPNCertificate') {
            $servicePrincipalCertificate = Add-Certificate -Endpoint $Endpoint -ServicePrincipal
        }
        else {
            $psCredential = New-Object System.Management.Automation.PSCredential(
                $Endpoint.Auth.Parameters.ServicePrincipalId,
                (ConvertTo-SecureString $Endpoint.Auth.Parameters.ServicePrincipalKey -AsPlainText -Force))
        }

        if ($script:azureModule -and $script:azureModule.Version -lt ([version]'0.9.9')) {
            # Service principals arent supported from 0.9.9 and greater in the Azure module.
            try {
                Write-Host "##[command]Add-AzureAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -Credential $psCredential"
                $null = Add-AzureAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -Credential $psCredential
            } catch {
                # Provide an additional, custom, credentials-related error message.
                Write-VstsTaskError -Message $_.Exception.Message
                Assert-TlsError -exception $_.Exception
                throw (New-Object System.Exception((Get-VstsLocString -Key AZ_ServicePrincipalError), $_.Exception))
            }

            Set-CurrentAzureSubscription -SubscriptionId $Endpoint.Data.SubscriptionId -StorageAccount $StorageAccount
        } elseif ($script:azureModule) {
            # Throw if >=0.9.9 Azure.
            throw (Get-VstsLocString -Key "AZ_ServicePrincipalAuthNotSupportedAzureVersion0" -ArgumentList $script:azureModule.Version)
        } else {
            # Else, this is AzureRM.            
            try {
                if (Get-Command -Name "Add-AzureRmAccount" -ErrorAction "SilentlyContinue") {                    
                    if (CmdletHasMember -cmdlet "Add-AzureRMAccount" -memberName "EnvironmentName") {
                        
                        if ($Endpoint.Auth.Parameters.AuthenticationType -eq "SPNCertificate") {
                            Write-Host "##[command]Add-AzureRMAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -CertificateThumbprint ****** -ApplicationId $($Endpoint.Auth.Parameters.ServicePrincipalId) -EnvironmentName $environmentName"
                            $null = Add-AzureRmAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -CertificateThumbprint $servicePrincipalCertificate.Thumbprint -ApplicationId $Endpoint.Auth.Parameters.ServicePrincipalId -EnvironmentName $environmentName
                        }
                        else {
                            Write-Host "##[command]Add-AzureRMAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -Credential $psCredential -EnvironmentName $environmentName"
                            $null = Add-AzureRMAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -Credential $psCredential -EnvironmentName $environmentName
                        }
                    }
                    else {
                        if ($Endpoint.Auth.Parameters.AuthenticationType -eq "SPNCertificate") {
                            Write-Host "##[command]Add-AzureRMAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -CertificateThumbprint ****** -ApplicationId $($Endpoint.Auth.Parameters.ServicePrincipalId) -Environment $environmentName"
                            $null = Add-AzureRmAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -CertificateThumbprint $servicePrincipalCertificate.Thumbprint -ApplicationId $Endpoint.Auth.Parameters.ServicePrincipalId -Environment $environmentName
                        }
                        else {
                            Write-Host "##[command]Add-AzureRMAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -Credential $psCredential -Environment $environmentName"
                            $null = Add-AzureRMAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -Credential $psCredential -Environment $environmentName
                        }
                    }
                }
                else {
                    if ($Endpoint.Auth.Parameters.AuthenticationType -eq "SPNCertificate") {
                        Write-Host "##[command]Connect-AzureRMAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -CertificateThumbprint ****** -ApplicationId $($Endpoint.Auth.Parameters.ServicePrincipalId) -Environment $environmentName"
                        $null = Connect-AzureRmAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -CertificateThumbprint $servicePrincipalCertificate.Thumbprint -ApplicationId $Endpoint.Auth.Parameters.ServicePrincipalId -Environment $environmentName
                    }
                    else {
                        Write-Host "##[command]Connect-AzureRMAccount -ServicePrincipal -Tenant $($Endpoint.Auth.Parameters.TenantId) -Credential $psCredential -Environment $environmentName"
                        $null = Connect-AzureRMAccount -ServicePrincipal -Tenant $Endpoint.Auth.Parameters.TenantId -Credential $psCredential -Environment $environmentName
                    }
                }
            } 
            catch {
                # Provide an additional, custom, credentials-related error message.
                Write-VstsTaskError -Message $_.Exception.Message
                Assert-TlsError -exception $_.Exception
                throw (New-Object System.Exception((Get-VstsLocString -Key AZ_ServicePrincipalError), $_.Exception))
            }
            
            if($scopeLevel -eq "Subscription")
            {
                Set-CurrentAzureRMSubscription -SubscriptionId $Endpoint.Data.SubscriptionId -TenantId $Endpoint.Auth.Parameters.TenantId
            }
        }
    } elseif ($Endpoint.Auth.Scheme -eq 'ManagedServiceIdentity') {
        $accountId = $env:BUILD_BUILDID 
        if($env:RELEASE_RELEASEID){
            $accountId = $env:RELEASE_RELEASEID 
        }
        $date = Get-Date -Format o
        $accountId = -join($accountId, "-", $date)
        $access_token = Get-MsiAccessToken $Endpoint
        try {
            Write-Host "##[command]Add-AzureRmAccount  -AccessToken ****** -AccountId $accountId "
            $null = Add-AzureRmAccount -AccessToken $access_token -AccountId $accountId
        } catch {
            # Provide an additional, custom, credentials-related error message.
            Write-VstsTaskError -Message $_.Exception.Message
            throw (New-Object System.Exception((Get-VstsLocString -Key AZ_MsiFailure), $_.Exception))
        }
        
        Set-CurrentAzureRMSubscription -SubscriptionId $Endpoint.Data.SubscriptionId -TenantId $Endpoint.Auth.Parameters.TenantId
    }else {
        throw (Get-VstsLocString -Key AZ_UnsupportedAuthScheme0 -ArgumentList $Endpoint.Auth.Scheme)
    } 
}

function Set-CurrentAzureSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        [string]$StorageAccount)

    $additional = @{ }
    if ($script:azureModule.Version -lt ([version]'0.8.15')) {
        $additional['Default'] = $true # The Default switch is required prior to 0.8.15.
    }

    Write-Host "##[command]Select-AzureSubscription -SubscriptionId $SubscriptionId $(Format-Splat $additional)"
    $null = Select-AzureSubscription -SubscriptionId $SubscriptionId @additional
    if ($StorageAccount) {
        Write-Host "##[command]Set-AzureSubscription -SubscriptionId $SubscriptionId -CurrentStorageAccountName $StorageAccount"
        Set-AzureSubscription -SubscriptionId $SubscriptionId -CurrentStorageAccountName $StorageAccount
    }
}

function Set-CurrentAzureRMSubscription {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SubscriptionId,
        [string]$TenantId)

    $additional = @{ }
    if ($TenantId) { $additional['TenantId'] = $TenantId }

    if (Get-Command -Name "Select-AzureRmSubscription" -ErrorAction "SilentlyContinue") {
        Write-Host "##[command] Select-AzureRMSubscription -SubscriptionId $SubscriptionId $(Format-Splat $additional)"
        $null = Select-AzureRMSubscription -SubscriptionId $SubscriptionId @additional
    }
    else {
        Write-Host "##[command] Set-AzureRmContext -SubscriptionId $SubscriptionId $(Format-Splat $additional)"
        $null = Set-AzureRmContext -SubscriptionId $SubscriptionId @additional
    }
}