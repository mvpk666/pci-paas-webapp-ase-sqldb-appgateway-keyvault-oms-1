<#
This script deploys and configures Azure resources as a part of a -pre-deployment- activity

This script should run before you start deployment of PCI-PaaS solution templates. Use your Azure AD Global Administrator account with
        Owner permission at Subscription level to execute this script. 
		If you are not sure about your permissions, run 0-Setup-AdministrativeAccountAndPermission.ps1 before you execute this script.

    This script performs several pre-requisites including 
        -   Create 2 Azure AD Accounts - 1) SQL Account with Company Administrator Role and Contributor Permission on a Subscription.
                                         2) Receptionist Account with Limited access.
        -   Creates AD Application and Service Principle to AD Application.
        -   Generates self-signed SSL certificate for Internal App Service Environment and Application gateway (if required) and Converts them into Base64 string
                for template deployment.
				
				
				
    You can use the following switches parameters - 
    1) enableSSL - Use this switch to create new self-signed certificate or convert existing certificate (by providing certificatePath) for Application Gateway SSL endpoint. 
    2) enableADDomainPasswordPolicy - Use this switch to setup password policy with 60 days of validity at Domain Level.

    
USAGE 1, Create Azure AD Accounts, self-signed certificate for ASE ILB, custom domain, self-signed certificate for Application Gateway & setup password policy with 60 days.
	
    .\1-DeployAndConfigureAzureResources.ps1 -globalAdminUserName admin1@contoso.com -globalAdminPassword ********** -azureADDomainName contoso.com -subscriptionID xxxxxxx-f760-xxxx-bd98-xxxxxxxx -suffix PCIDemo -sqlTDAlertEmailAddress email@dummy.com -customHostName dummydomain.com -enableSSL -enableADDomainPasswordPolicy

    
USAGE 2, Create Azure AD Accounts, self-signed certificate for ASE ILB, custom domain, self-signed certificate for Application Gateway & setup password policy with 60 days.
    
	
   .\1-DeployAndConfigureAzureResources.ps1 -globalAdminUserName admin1@contoso.com -globalAdminPassword ********** -azureADDomainName contoso.com -subscriptionID xxxxxxx-f760-xxxx-bd98-xxxxxxxx -suffix PCIDemo -sqlTDAlertEmailAddress email@dummy.com -enableSSL -enableADDomainPasswordPolicy

 
USAGE 3,  Create Azure AD Accounts & self-signed certificate for ASE ILB with default customHostName only

    .\1-DeployAndConfigureAzureResources.ps1 -globalAdminUserName admin1@contoso.com -globalAdminPassword ********** -azureADDomainName contoso.com -subscriptionID xxxxxxx-f760-xxxx-bd98-xxxxxxxx -suffix PCIDemo -sqlTDAlertEmailAddress email@dummy.com

    
  
#>
[CmdletBinding()]
Param
    (
        # Provide resourceGroupName for deployment
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [ValidateLength(1,64)]
        [ValidatePattern('^[\w]+$')]
        $resourceGroupName,

        # Provide location for deployment
        [Parameter(Mandatory=$true)] 
        [ValidateSet("eastasia","southeastasia","centralus","eastus","eastus2","westus","northcentralus","southcentralus","northeurope","westeurope","japanwest","japaneast",
        "brazilsouth","australiaeast","australiasoutheast","southindia","centralindia","westindia","canadacentral","canadaeast","uksouth","ukwest","westcentralus","westus2",
        "koreacentral","koreasouth")]
        [string]
        $location,

        # Provide Azure AD UserName with Global Administrator permission on Azure AD and Service Administrator / Co-Admin permission on Subscription.
        [Parameter(Mandatory=$True)] 
        [string]$globalAdminUserName, 

        # Provide password for Azure AD UserName.
        [Parameter(Mandatory=$True)] 
        [string]$globalAdminPassword,

        # Provide Azure AD Domain Name.
        [Parameter(Mandatory=$true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $azureADDomainName,

        # Provide Subscription ID that will be used for deployment
        [Parameter(Mandatory=$true)]
        [string]
        [ValidateNotNullOrEmpty()]
        $subscriptionID,

        # This is used to create a unique website name in your organization. This could be your company name or business unit name
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]
        $suffix,

        # Provide Supported location/Region for Automation Account
        [Parameter(Mandatory=$true)]
        [ValidateSet("japaneast","eastus2","westeurope","southeastasia","southcentralus","uksouth","westcentralus","northeurope","canadacentral","australiasoutheast",
        "centralindia")]
        [string]
        $automationAcclocation,
        
        # Provide Email address for SQL Threat Detection Alerts
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]        
        $sqlTDAlertEmailAddress,
        
        # Provide template Uri for deployment template
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]        
        $templateUri,

        # Provide artifacts location that will be uploaded to storage account
        [Parameter(Mandatory=$true)]
        [ValidateNotNullOrEmpty()]
        [string]        
        $_artifactslocation,            

        # Provide CustomDomain that will be used for creating ASE SubDomain & WebApp HostName e.g. contoso.com. This is not a Mandatory parameter. You can also leave
        #   it blank if you want to use built-in domain - azurewebsites.net. 
        [string]
        $customHostName = "azurewebsites.net",

        # Provide certificate path if you are wiling to provide your own frontend ssl certificate for Application gateway.
        [ValidateScript({
            if(
                (Test-Path $_)
            ){$true}
            else {Throw "Parameter validtion failed due to invalid file path"}
        })]  
        [string]
        $certificatePath,

        # Enter password for the certificate provided.
        [string]
        $certificatePassword,

        # Use this swtich in combination with certificatePath parameter to setup frontend ssl on Application gateway.
        [ValidateScript({
            if(
                (Get-Variable customHostName)
            ){$true}
            else {Throw "Parameter validtion failed due to invalid customHostName"}
        })]         
        [switch]
        $enableSSL,

        # Use this switch to enable new password policy with 60 days expiry at Azure AD Domain level.
        [switch]$enableADDomainPasswordPolicy               
    )

Begin
    {
        $errorActionPreference = 'stop'
        Set-location $PSScriptRoot    

        ########### Manage directories ###########
        # Create folder to store self-signed certificates
        if(!(Test-path $pwd\Certificates)){mkdir $pwd\Certificates -Force | Out-Null }

        ########### Functions ###########
        Write-Host -ForegroundColor Green "`nStep 1: Loading functions."
        # Function to convert certificates into Base64 String.
        function Convert-Certificate ($certPath)
        {
            $fileContentBytes = get-content "$certPath" -Encoding Byte
            [System.Convert]::ToBase64String($fileContentBytes)
        }

        # Function to create a strong 15 length Strong & Random password for the solution.
        function New-RandomPassword () 
        {
            # This function generates a strong 15 length random password using Capital & Small Aplhabets,Numbers and Special characters.
            (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})) + `
            ((10..99) | Get-Random -Count 1) + `
            ('@','%','!','^' | Get-Random -Count 1) +`
            (-join ((65..90) + (97..122) | Get-Random -Count 5 | % {[char]$_})) + `
            ((10..99) | Get-Random -Count 1)
        }

        #  Function for self-signed certificate generator. Reference link - https://gallery.technet.microsoft.com/scriptcenter/Self-signed-certificate-5920a7c6
        .".\1-click-deployment-nested\New-SelfSignedCertificateEx.ps1"

        Write-Host -ForegroundColor Yellow "`t* Functions loaded successfully."

        ########### Manage Variables ###########
        $scriptFolder = Split-Path -Parent $PSCommandPath
        $sqlADAdminName = "sqlAdmin@"+$azureADDomainName
        $receptionistUserName = "receptionist_EdnaB@"+$azureADDomainName
        $pciAppServiceURL = "http://pcisolution"+(Get-Random -Maximum 999)+'.'+$azureADDomainName
        $suffix = $suffix.Replace(' ', '').Trim()
        $displayName = ($suffix + " Azure PCI PAAS Sample")
        if($enableSSL){
            $sslORnon_ssl = 'ssl'
        }else{
            $sslORnon_ssl = 'non-ssl'
        }
        $automationaccname = "automationacc" + ((Get-Date).ToUniversalTime()).ToString('MMddHH')
        $automationADApplication = "AutomationAppl" + ((Get-Date).ToUniversalTime()).ToString('MMddHH')
        $deploymentName = "PCI-Deploy-"+ ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')
        $_artifactslocationSasToken = "null"

        # Generating common password 
        $newPassword = New-RandomPassword
        $secNewPasswd = ConvertTo-SecureString $newPassword -AsPlainText -Force

        # Creating a Login credential.
        $secpasswd = ConvertTo-SecureString $globalAdminPassword -AsPlainText -Force
        $psCred = New-Object System.Management.Automation.PSCredential ($globalAdminUserName, $secpasswd)

        ########### Establishing connection to Azure ###########
        try {
            Write-Host -ForegroundColor Green "`nStep 2: Establishing connection to Azure AD & Subscription"

            # Connecting to MSOL Service
            Write-Host -ForegroundColor Yellow  "`t* Connecting to Msol service."
            Connect-MsolService -Credential $psCred | Out-null
            if(Get-MsolDomain){
                Write-Host -ForegroundColor Yellow "`t* Connection to Msol Service established successfully."
            }
            
            # Connecting to Azure Subscription
            Write-Host -ForegroundColor Yellow "`t* Connecting to AzureRM Subscription - $subscriptionID."
            Login-AzureRmAccount -Credential $psCred -SubscriptionId $subscriptionID | Out-null
            if(Get-AzureRmContext){
                Write-Host -ForegroundColor Yellow "`t* Connection to AzureRM Subscription established successfully."
            }
        }
        catch {
            Throw $_
        }
    }
Process
    {

        try {
            ########### Creating Users in Azure AD ###########
            Write-Host ("`nStep 3: Create AD Users for SQL AD Admin & Receptionist to test various scenarios" ) -ForegroundColor Green
            
            # Creating SQL Admin & Receptionist Account if does not exist already.
            Write-Host -ForegroundColor Yellow "`t* Checking is $sqlADAdminName already exist in the directory."
            $sqlADAdminDetails = Get-MsolUser -UserPrincipalName $sqlADAdminName -ErrorAction SilentlyContinue
            $sqlADAdminObjectId= $sqlADAdminDetails.ObjectID
            if ($sqlADAdminObjectId -eq $null)  
            {    
                $sqlADAdminDetails = New-MsolUser -UserPrincipalName $sqlADAdminName -DisplayName "SQLADAdministrator PCI Samples" -FirstName "SQL AD Administrator" -LastName "PCI Samples" -PasswordNeverExpires $false -StrongPasswordRequired $true
                $sqlADAdminObjectId= $sqlADAdminDetails.ObjectID
                # Make the SQL Account a Global AD Administrator
                Write-Host -ForegroundColor Yellow "`t* Promoting SQL AD User Account as Company Administrator."
                Add-MsolRoleMember -RoleName "Company Administrator" -RoleMemberObjectId $sqlADAdminObjectId
            }

            # Setting up new password for SQL Global AD Admin.
            Write-Host -ForegroundColor Yellow "`t* Setting up password for SQL AD Admin Account"
            Set-MsolUserPassword -userPrincipalName $SQLADAdminName -NewPassword $newPassword -ForceChangePassword $false | Out-Null
            Start-Sleep -Seconds 30

            # Grant 'SQL Global AD Admin' access to the Azure subscription
            $RoleAssignment = Get-AzureRmRoleAssignment -ObjectId $sqlADAdminObjectId -RoleDefinitionName Contributor -Scope ('/subscriptions/'+ $subscriptionID) -ErrorAction SilentlyContinue
            if ($RoleAssignment -eq $null){
                Write-Host -ForegroundColor Yellow "`t* Assigning $($sqlADAdminDetails.SignInName) with Contributor Role on Subscription - $subscriptionID"
                New-AzureRmRoleAssignment -ObjectId $sqlADAdminObjectId -RoleDefinitionName Contributor -Scope ('/subscriptions/' + $subscriptionID )
                if (Get-AzureRmRoleAssignment -ObjectId $sqlADAdminObjectId -RoleDefinitionName Contributor -Scope ('/subscriptions/'+ $subscriptionID))
                {
                    Write-Host -ForegroundColor Cyan "`t* $($sqlADAdminDetails.SignInName) has been successfully assigned with Contributor Role on Subscription."
                }
            }
            else{ Write-Host -ForegroundColor Cyan "`t* $($sqlADAdminDetails.SignInName) has already been assigned with Contributor Role on Subscription."}

            Write-Host -ForegroundColor Yellow "`t* Checking is $receptionistUserName already exist in the directory."
            $receptionistUserObjectId = (Get-MsolUser -UserPrincipalName $receptionistUserName -ErrorAction SilentlyContinue).ObjectID
            if ($receptionistUserObjectId -eq $null)  
            {    
                New-MsolUser -UserPrincipalName $receptionistUserName -DisplayName "Edna Benson" -FirstName "Edna" -LastName "Benson" -PasswordNeverExpires $false -StrongPasswordRequired $true
            }
            # Setting up new password for Receptionist user account.
            Write-Host -ForegroundColor Yellow "`t* Setting up password for Receptionist User Account"
            Set-MsolUserPassword -userPrincipalName $receptionistUserName -NewPassword $newPassword -ForceChangePassword $false | Out-Null
        }
        catch {
            throw $_
        }

        try {
            ########### Create Azure Active Directory apps in default directory ###########
            Write-Host ("`nStep 4: Create Azure AD application in Default directory") -ForegroundColor Green
            # Get tenant ID
            $tenantID = (Get-AzureRmContext).Tenant.TenantId
            if ($tenantID -eq $null){$tenantID = (Get-AzureRmContext).Tenant.Id}

            # Create Active Directory Application
            Write-Host ("`t* Step 4.1: Attempting to Azure AD application") -ForegroundColor Yellow
            $azureAdApplication = New-AzureRmADApplication -DisplayName $displayName -HomePage $pciAppServiceURL -IdentifierUris $pciAppServiceURL -Password $newPassword
            $azureAdApplicationClientId = $azureAdApplication.ApplicationId.Guid
            $azureAdApplicationObjectId = $azureAdApplication.ObjectId.Guid            
            Write-Host ("`t* Azure Active Directory apps creation successful. AppID is " + $azureAdApplication.ApplicationId) -ForegroundColor Yellow

            # Create a service principal for the AD Application and add a Reader role to the principal 
            Write-Host ("`t* Step 4.2: Attempting to create Service Principal") -ForegroundColor Yellow
            $principal = New-AzureRmADServicePrincipal -ApplicationId $azureAdApplication.ApplicationId
            Start-Sleep -s 30 # Wait till the ServicePrincipal is completely created. Usually takes 20+secs. Needed as Role assignment needs a fully deployed servicePrincipal
            Write-Host ("`t* Service Principal creation successful - " + $principal.DisplayName) -ForegroundColor Yellow
            Start-Sleep -Seconds 30

            # Assign Reader Role to Service Principal on Azure Subscription
            $scopedSubs = ("/subscriptions/" + $subscriptionID)
            Write-Host ("`t* Step 4.3: Attempting Reader Role assignment" ) -ForegroundColor Yellow
            New-AzureRmRoleAssignment -RoleDefinitionName Reader -ServicePrincipalName $azureAdApplication.ApplicationId.Guid -Scope $scopedSubs | Out-Null
            Write-Host ("`t* Reader Role assignment successful" ) -ForegroundColor Yellow    
        }
        catch {
            throw $_
        }

        try {
            ########### Create Self-signed certificate for ASE ILB and Application Gateway ###########
            Write-Host -ForegroundColor Green "`nStep 5: Create Self-signed certificate for ASE ILB and Application Gateway "

            # Generate App Gateway Front End SSL certificate, if required and converts it to Base64 string.
            if($enableSSL){
                if($certificatePath) {
                    Write-Host -ForegroundColor Yellow "`t* Converting customer provided certificate to Base64 string"
                    $certData = Convert-Certificate -certPath $certificatePath
                    $certPassword = "Customer provided certificate."
                }
                else{
                    Write-Host -ForegroundColor Yellow "`t* No valid certificate path was provided. Creating a new self-signed certificate and converting to Base64 string"
                    $fileName = "appgwfrontendssl"
                    $certificate = New-SelfSignedCertificateEx -Subject "CN=www.$customHostName" -SAN "www.$customHostName" -EKU "Server Authentication", "Client authentication" `
                    -NotAfter $([datetime]::now.AddYears(5)) -KU "KeyEncipherment, DigitalSignature" -SignatureAlgorithm SHA256 -Exportable
                    $certThumbprint = "cert:\CurrentUser\my\" + $certificate.Thumbprint
                    Write-Host -ForegroundColor Yellow "`t* Certificate created successfully. Exporting certificate into pfx format."
                    Export-PfxCertificate -cert $certThumbprint -FilePath "$scriptFolder\Certificates\$fileName.pfx" -Password $secNewPasswd | Out-null
                    $certData = Convert-Certificate -certPath "$scriptFolder\Certificates\$fileName.pfx"
                    $certPassword = $newPassword
                }
            }
            else{
                $certData = "null"
                $certPassword = "null"
            }

            ### Generate self-signed certificate for ASE ILB and convert into base64 string
            Write-Host -ForegroundColor Yellow "`t* Creating a self-signed certificate for ASE ILB and converting to Base64 string"
            $fileName = "aseilbcertificate"
            $certificate = New-SelfSignedCertificateEx -Subject "CN=*.ase.$customHostName" -SAN "*.ase.$customHostName", "*.scm.ase.$customHostName" -EKU "Server Authentication", "Client authentication" `
            -NotAfter $([datetime]::now.AddYears(5)) -KU "KeyEncipherment, DigitalSignature" -SignatureAlgorithm SHA256 -Exportable
            $certThumbprint = "cert:\CurrentUser\my\" + $certificate.Thumbprint
            Write-Host -ForegroundColor Yellow "`t* Certificate created successfully. Exporting certificate into .pfx & .cer format."
            Export-PfxCertificate -cert $certThumbprint -FilePath "$scriptFolder\Certificates\$fileName.pfx" -Password $secNewPasswd | Out-null
            Export-Certificate -Cert $certThumbprint -FilePath "$scriptFolder\Certificates\$fileName.cer" | Out-null
            Start-Sleep -Seconds 3
            $aseCertData = Convert-Certificate -certPath "$scriptFolder\Certificates\$fileName.cer"
            $asePfxBlobString = Convert-Certificate -certPath "$scriptFolder\Certificates\$fileName.pfx"
            $asePfxPassword = $newPassword
            $aseCertThumbprint = $certificate.Thumbprint
        }
        catch {
            throw $_
        }

        # Setup up Password Policy at Azure AD Domain Level, if allowed.
        try{
            if($enableADDomainPasswordPolicy){
                Write-Host -ForegroundColor Green "`nStep 6: Setting up password policy for $azureADDomainName domain"
                Set-MsolPasswordPolicy -ValidityPeriod 60 -NotificationDays 14 -DomainName "$azureADDomainName"
                if (($passwordPolicy = Get-MsolPasswordPolicy -DomainName $azureADDomainName).ValidityPeriod -eq 60 ) {
                    Write-Host -ForegroundColor Yellow "`t* Password policy has been set to 60 Days."
                    $passwordValidityPeriod = $passwordPolicy.ValidityPeriod
                }else{
				Write-Host -ForegroundColor Red "`t* Failed to set password policy to 60 Days." 
				Write-Host -ForegroundColor Yellow "Please refer output for current password policy settings."
				}
            }
        }
        catch{
            throw $_
        }

        # Create Resource group, Automation account, RunAs Account for Runbook and Initiate template deployment
        try {
                Write-Host -ForegroundColor Yellow "`nStep 7: Preparing for Template Deployment"
                # Create Resource Group
                Write-Output "`t* Creating a New Resource Group - $resourceGroupName at $location"
                New-AzureRmResourceGroup -Name $resourceGroupName -location $location -Force | Out-Null
                Write-Host -ForegroundColor Yellow "`t* ResoureGroup - $resourceGroupName has been created successfully"
                Start-Sleep -Seconds 5

                # Create Automation Account
                Write-Host -ForegroundColor Yellow "`t* Creating an Automation Account -$automationaccname at $automationAcclocation under Resource Group - $resourceGroupName"
                New-AzureRmAutomationAccount -Name "$automationaccname" -location "$automationAcclocation" -resourceGroupName "$resourceGroupName" | Out-Null
                Write-Host -ForegroundColor Yellow "`t* Automation Account has been created successfully"
                Start-Sleep -Seconds 5

                # Create Automation Run-As Account to execute runbooks
                Write-Host -ForegroundColor Yellow "`t* Creating RunAs account for runbooks to execute."
                .\Scripts\New-RunAsAccount.ps1 -ResourceGroup $resourceGroupName -AutomationAccountName $automationaccname -SubscriptionId $subscriptionID -ApplicationDisplayName $automationADApplication `
                -SelfSignedCertPlainPassword $newPassword -CreateClassicRunAsAccount $false
                Start-Sleep -Seconds 5

                Start-Process Powershell -ArgumentList "-NoExit", ".\Scripts\New-Deployment.ps1 -DeploymentName $deploymentName -ResourceGroupName $resourceGroupName -Location $location `
                -TemplateUri $templateUri -_artifactsLocation $_artifactsLocation -_artifactsLocationSasToken $_artifactsLocationSasToken -sslORnon_ssl $sslORnon_ssl -certData $certData `
                -certPassword $certPassword -aseCertData $aseCertData -asePfxBlobString $asePfxBlobString -asePfxPassword $asePfxPassword -aseCertThumbprint $aseCertThumbprint `
                -bastionHostAdministratorPassword $newPassword -sqlAdministratorLoginPassword $newPassword -sqlThreatDetectionAlertEmailAddress $SqlTDAlertEmailAddress -automationAccountName $automationaccname `
                -customHostName $customHostName -azureAdApplicationClientId $azureAdApplicationClientId -azureAdApplicationClientSecret $newPassword -azureAdApplicationObjectId $azureAdApplicationObjectId `
                -sqlAdAdminUserName $SQLADAdminName -sqlAdAdminUserPassword $newPassword"
            }

        catch {
            
        }























    }
End
    {
        Write-Host -ForegroundColor Green "Common variables created for deployment"

        Write-Host -ForegroundColor Green "`n########################### Template Input Parameters - Start ###########################"
        $templateInputTable = New-Object -TypeName Hashtable
        $templateInputTable.Add('sslORnon_ssl',$sslORnon_ssl)
        $templateInputTable.Add('certData',$certData)
        $templateInputTable.Add('certPassword',$certPassword)
        $templateInputTable.Add('aseCertData',$aseCertData)
        $templateInputTable.Add('asePfxBlobString',$asePfxBlobString)
        $templateInputTable.Add('asePfxPassword',$asePfxPassword)
        $templateInputTable.Add('aseCertThumbprint',$aseCertThumbprint)
        $templateInputTable.Add('bastionHostAdministratorUserName','bastionadmin')
        $templateInputTable.Add('bastionHostAdministratorPassword',$newPassword)
        $templateInputTable.Add('sqlAdministratorLoginUserName','sqladmin')
        $templateInputTable.Add('sqlAdministratorLoginPassword',$newPassword)
        $templateInputTable.Add('sqlThreatDetectionAlertEmailAddress',$sqlTDAlertEmailAddress)
        $templateInputTable.Add('customHostName',$customHostName)
        $templateInputTable.Add('azureAdApplicationClientId',$azureAdApplicationClientId)
        $templateInputTable.Add('azureAdApplicationClientSecret',$newPassword)        
        $templateInputTable.Add('azureAdApplicationObjectId',$azureAdApplicationObjectId)
        $templateInputTable.Add('sqlAdAdminUserName',$sqlADAdminName)
        $templateInputTable.Add('sqlAdAdminUserPassword',$newPassword)
        $templateInputTable | Sort-Object Name  | Format-Table -AutoSize -Wrap -Expand EnumOnly 
        Write-Host -ForegroundColor Green "`n########################### Template Input Parameters - End ###########################"

        Write-Host -ForegroundColor Green "`n########################### Other Deployment Details - Start ###########################"
        $outputTable = New-Object -TypeName Hashtable
        $outputTable.Add('tenantId',$tenantID)
        $outputTable.Add('subscriptionId',$subscriptionID)
        $outputTable.Add('receptionistUserName',$receptionistUserName)
        $outputTable.Add('receptionistPassword',$newPassword)
        $outputTable.Add('passwordValidityPeriod',$passwordValidityPeriod)
        $outputTable | Sort-Object Name  | Format-Table -AutoSize -Wrap -Expand EnumOnly 
        Write-Host -ForegroundColor Green "`n########################### Other Deployment Details - End ###########################"

    }


####################  End of Script ###############################