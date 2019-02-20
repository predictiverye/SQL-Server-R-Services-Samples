<#
.SYNOPSIS
Script to train and test the preventive maintenance template with SQL + MLS

.DESCRIPTION
This script will show the E2E work flow of Preventive Maintenance machine learning
template with Microsoft SQL and ML services. 

For the detailed description, please read README.md.
#>



[CmdletBinding()]
param(
# SQL server address
[parameter(Mandatory=$false,ParameterSetName = "Train_test")]
[ValidateNotNullOrEmpty()] 
[String]    
$serverName = "",

[parameter(Mandatory=$false, Position=2)]
[ValidateNotNullOrEmpty()] 
[string]$username,

[parameter(Mandatory=$false, Position=3)]
[ValidateNotNullOrEmpty()] 
[string]$password,

[parameter(Mandatory=$false, Position=4)]
[ValidateNotNullOrEmpty()] 
[string]$Prompt

)

###Check to see if user is Admin

$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(`
        [Security.Principal.WindowsBuiltInRole] "Administrator")
        
if ($isAdmin -eq 'True')
{
    ##Change Values here for Different Solutions 
    $SolutionName = "PredictiveMaintenance"
    $SolutionFullName = "SQL-Server-R-Services-Samples" 
    $Shortcut = $SolutionName+"Help.url"
    $DatabaseName = "PredictiveMaintenance_R" 

    $Branch = "master" 
    $InstallR = 'Yes'  ## If Solution has a R Version this should be 'Yes' Else 'No'
    $InstallPy = 'No' ## If Solution has a Py Version this should be 'Yes' Else 'No'
    $SampleWeb = 'No' ## If Solution has a Sample Website  this should be 'Yes' Else 'No' 
    $EnableFileStream = 'No' ## If Solution Requires FileStream DB this should be 'Yes' Else 'No'
    $IsMixedMode = 'Yes' ##If solution needs mixed mode this should be 'Yes' Else 'No'
    $Prompt = 'N'

    ###These probably don't need to change , but make sure files are placed in the correct directory structure 
    $solutionTemplateName = "Solutions"
    $solutionTemplatePath = "C:\" + $SolutionFullName
    $checkoutDir = $SolutionName
    $SolutionPath = $solutionTemplatePath + '\' + $checkoutDir
    $desktop = "C:\Users\Public\Desktop\"
    $scriptPath = $SolutionPath + "\SQLR\"
    $SolutionData = $SolutionPath + "\Data\"
    $moreSolutionsURL = "https://github.com/Microsoft/ML-Server/"
    $setupLog = "c:\tmp\"+$SolutionName+"_setup_log.txt"
    $installerFunctionsFileName = "installer_functions.ps1"
    $installerFunctionsURL = "https://raw.githubusercontent.com/Microsoft/ML-Server/master/$installerFunctionsFileName"
    $installerFunctionsFile = "$PSScriptRoot\$installerFunctionsFileName"
        
    ##########################################################################
    # Including function wrapper library
    ##########################################################################
    try {
        if (Test-Path $installerFunctionsFile) {
            Remove-Item $installerFunctionsFile
        }
        Invoke-WebRequest -uri $installerFunctionsURL -OutFile $installerFunctionsFile
        .($installerFunctionsFile)
    }
    catch {
        Write-Host -ForegroundColor Red "Error while loading supporting PowerShell Scripts."
        Write-Host -ForegroundColor Red $_Exception
        EXIT
    }

    WriteInstallStartMessage -SolutionName $SolutionName
    
    Start-Transcript -Path $setupLog
    $startTime = Get-Date
    Write-Host ("Start time: $startTime")

    Write-Host -Foregroundcolor green ("Performing set up.")

    ##########################################################################
    # Get connection string function
    ##########################################################################
    function GetConnectionString
    {
        if($IsMixedMode.ToUpper() -eq "YES") {
            $connectionString = "Driver=SQL Server;Server=$serverName;Database=$DatabaseName;UID=$username;PWD=$password"
        }
        else {
            $connectionString = "Driver=SQL Server;Server=$servername;Database=$DatabaseName;Trusted_Connection=Yes"
        }
        $connectionString
    }
    

    ##########################################################################
    # Construct the SQL connection strings
    ##########################################################################
        $connectionString = GetConnectionString
    
    
    ##################################################################
    ##DSVM Does not have SQLServer Powershell Module Install or Update 
    ##################################################################
        InstallOrUpdateSQLServerPowerShellModule

    ##########################################################################
    ##Clone Data from GIT
    ##########################################################################
        CloneFromGIT -SolutionFullName $SolutionFullName, -solutionTemplatePath $solutionTemplatePath -SolutionPath $SolutionPath

    ##########################################################################
    #Install R packages if required
    ##########################################################################
        InstallRPackages -SolutionPath $SolutionPath

    ##########################################################################
    #Enabled FileStream if required
    ##########################################################################
        ## if FileStreamDB is Required Alter Firewall ports for 139 and 445
        If ($EnableFileStream -eq 'Yes') {
            netsh advfirewall firewall add rule name="Open Port 139" dir=in action=allow protocol=TCP localport=139
            netsh advfirewall firewall add rule name="Open Port 445" dir=in action=allow protocol=TCP localport=445
            Write-Host("Firewall as been opened for filestream access")
        }
        If ($EnableFileStream -eq 'Yes') {
            Set-Location "C:\Program Files\Microsoft\ML Server\PYTHON_SERVER\python.exe" 
            .\setup.py install
            Write-Host ("Py Install has been updated to latest version")
        }

    ############################################################################################
    #Configure SQL to Run our Solutions 
    ############################################################################################
        ##Get Server name if none was provided during setup

        if([string]::IsNullOrEmpty($serverName)) {
            $Query = "SELECT SERVERPROPERTY('ServerName')"
            $si = Invoke-Sqlcmd -Query $Query
            $si = $si.Item(0)
        }
        else {
            $si = $serverName
        }
        $serverName = $si
        Write-Host("Servername set to $serverName")

        ### Change Authentication From Windows Auth to Mixed Mode 
        ChangeAuthenticationFromWindowsToMixed -servername $servername -IsMixedMode $IsMixedMode -username $username -password $password

        Write-Host("Configuring SQL to allow running of External Scripts")
        ### Allow Running of External Scripts , this is to allow R Services to Connect to SQL
        ExecuteSQL -query "EXEC sp_configure  'external scripts enabled', 1" -dbName "master"

        ### Force Change in SQL Policy on External Scripts 
        ExecuteSQL -query "RECONFIGURE WITH OVERRIDE" -dbName "master"
        Write-Host("SQL Server Configured to allow running of External Scripts")

        ### Enable FileStreamDB if Required by Solution 
        if ($EnableFileStream -eq 'Yes') {
            # Enable FILESTREAM
            $instance = "MSSQLSERVER"
            $wmi = Get-WmiObject -Namespace "ROOT\Microsoft\SqlServer\ComputerManagement14" -Class FilestreamSettings | where-object {$_.InstanceName -eq $instance}
            $wmi.EnableFilestream(3, $instance)
            Stop-Service "MSSQ*" -Force
            Start-Service "MSSQ*"
 
            Set-ExecutionPolicy Unrestricted
            #Import-Module "sqlps" -DisableNameChecking
            ExecuteSQL -query "EXEC sp_configure filestream_access_level, 2" -dbName "master"
            ExecuteSQL -query "RECONFIGURE WITH OVERRIDE" -dbName "master"
            Stop-Service "MSSQ*"
            Start-Service "MSSQ*"
        }
        else { 
            Write-Host("Restarting SQL Services")
            ### Changes Above Require Services to be cycled to take effect 
            ### Stop the SQL Service and Launchpad wild cards are used to account for named instances  
            Restart-Service -Name "MSSQ*" -Force
        }

    ##########################################################################
    # Install Power BI
    ##########################################################################
    InstallPowerBI

    ##########################################################################
    # Create Shortcuts
    ##########################################################################
        ##Create Shortcuts and Autostart Help File 
        $shortcutpath = $scriptPath+$Shortcut
        Copy-Item $shortcutpath C:\Users\Public\Desktop\
        Copy-Item $shortcutpath "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\StartUp\"
        $WsShell = New-Object -ComObject WScript.Shell
        $shortcut = $WsShell.CreateShortcut($desktop + $checkoutDir + ".lnk")
        $shortcut.TargetPath = $solutionPath
        $shortcut.Save()
        Write-Host("Shortcuts made on Desktop")

    
    ##########################################################################
    # Check if the SQL server and database exists
    ##########################################################################
        $query = "IF NOT EXISTS(SELECT * FROM sys.databases WHERE NAME = '$DatabaseName') CREATE DATABASE $DatabaseName"
        #Invoke-Sqlcmd -ServerInstance $serverName -Username $username -Password $password -Query $query -ErrorAction SilentlyContinue
        ExecuteSQL -query $query -dbName "master"
        if ($? -eq $false)
        {
            Write-Host -ForegroundColor Red "Failed the test to connect to SQL server: $serverName database: $DatabaseName !"
            Write-Host -ForegroundColor Red "Please make sure: `n`t 1. SQL Server: $serverName exists;
                                             `n`t 2. The current user has the right credential for SQL server access."
            exit
        }
        $query = "USE $DatabaseName;"
        ExecuteSQL -query $query -dbName "master"
        Write-Host("Using database $DatabaseName")
    
    ##########################################################################
    # Create tables for train and test and populate with data from csv files.
    ##########################################################################
    Write-Host -ForeGroundColor 'green' ("Step 1: Create and populate train and test tables in Database {0}" -f $DatabaseName)
    if($Prompt -ne 'N') {
        #Prompt user
        $ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
        if ($ans -eq 'E' -or $ans -eq 'e')
        {
            return
        } 
    }
    else {
        #skip prompting since $Prompt -eq 'N' and set answer to 'y' to continue
        $ans = 'y'
    }
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
        try
        {
            # check if required R packages are installed
            Write-Host -ForeGroundColor 'green' ("Check required R packages")
            $script = $scriptPath + "DataProcessing\check_packages.sql"
            ExecuteSQLScript $script

            # create training and test tables
            Write-Host -ForeGroundColor 'green' ("Create SQL tables: PM_train, PM_test, PM_truth and PM_models:")
            $script = $scriptPath + "DataProcessing\create_table.sql"
            ExecuteSQLScript $script
            
            Write-Host -ForeGroundColor 'green' ("Populate SQL tables: PM_train, PM_test and PM_truth")
            $dataList = "PM_Train", "PM_test", "PM_Truth"
		
		    # upload csv files into SQL tables
            foreach ($dataFile in $dataList)
            {
                $destination = $SolutionPath + "\data\" + $dataFile + ".csv"
                Write-Host -ForeGroundColor 'magenta'("    Populate SQL table: {0}..." -f $dataFile)
                $tableName = $DatabaseName + ".dbo." + $dataFile
                $tableSchema = $SolutionPath + "\data\" + $dataFile + ".xml"
                
                ExecuteBCP("bcp $tableName format nul -c -x -f $tableSchema -t ','")
                Write-Host -ForeGroundColor 'magenta'("    Loading {0} to SQL table..." -f $dataFile)
                ExecuteBCP("bcp $tableName in $destination -t ',' -f $tableSchema -F 2 -C 'RAW' -b 20000")
                Write-Host -ForeGroundColor 'magenta'("    Done...Loading {0} to SQL table..." -f $dataFile)
            }
        }
        catch
        {
            Write-Host -ForegroundColor DarkYellow "Exception in populating train and test database tables:"
            Write-Host -ForegroundColor Red $Error[0].Exception 
            throw
        }
    }
    ##########################################################################
    # Create and execute the stored procedure for data labeling and 
    # feature engineering
    ##########################################################################
    Write-Host -ForeGroundColor 'green' ("Step 2: Data labeling and feature engineering")
    if($Prompt -ne 'N') {
        #Prompt user
        $ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
        if ($ans -eq 'E' -or $ans -eq 'e')
        {
            return
        } 
    }
    else {
        #skip prompting since $Prompt -eq 'N' and set answer to 'y' to continue
        $ans = 'y'
    } 
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
        try
        {
            # creat the stored procedure for data labeling
            Write-Host -ForeGroundColor 'magenta'("    Create SQL stored procedure for data labeling...")
            $script = $scriptPath + "DataProcessing/data_labeling.sql"
            ExecuteSQLScript $script
            
            # execute the feature engineering for training data
            Write-Host -ForeGroundColor 'magenta'("    Data labeling for training dataset...")
            $datasetType = 'train'
            $query = "EXEC data_labeling $datasetType, '$connectionString'"
            
            ExecuteSQL $query
            
            # execute the feature engineering for testing data
            Write-Host -ForeGroundColor 'magenta'("    Data labeling for testing dataset...")
            $datasetType = 'test'
            $query = "EXEC data_labeling $datasetType, '$connectionString'"
            ExecuteSQL $query

            # creat the stored procedure for feature engineering
            Write-Host -ForeGroundColor 'magenta'("    Create SQL stored procedure for feature engineering...")
            $script = $scriptPath + "DataProcessing/feature_engineering.sql"
            ExecuteSQLScript $script

            # execute the feature engineering for training data
            Write-Host -ForeGroundColor 'magenta'("    Execute feature engineering for training dataset...")
            $datasetType = 'train'
            $query = "EXEC feature_engineering $datasetType, '$connectionString'"
            ExecuteSQL $query

            # execute the feature engineering for testing data
            Write-Host -ForeGroundColor 'magenta'("    Execute feature engineering for testing dataset...")
            $datasetType = 'test'
            $query = "EXEC feature_engineering $datasetType, '$connectionString'"
            ExecuteSQL $query
        }
        catch
        {
            Write-Host -ForegroundColor DarkYellow "Exception in data labeling and feature engineering:"
            Write-Host -ForegroundColor Red $Error[0].Exception 
            throw
        }
    }

    ################################################################################
    # Create and execute the stored procedures for regression models
    ################################################################################
    Write-Host -ForeGroundColor 'green' ("Step 3a Training/Testing: Regression models")
    if($Prompt -ne 'N') {
        #Prompt user
        $ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
        if ($ans -eq 'E' -or $ans -eq 'e')
        {
            return
        } 
    }
    else {
        #skip prompting since $Prompt -eq 'N' and set answer to 'y' to continue
        $ans = 'y'
    }
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
        try
        {
            # create the stored procedure for regression models
            Write-Host -ForeGroundColor 'magenta'("    Create and upload the stored procedures for Regression models...")
            $regression = $scriptPath + "Regression/*_regression_*.sql"
            Get-ChildItem $regression | ForEach-Object -Process {ExecuteSQLScript -scriptFile $_.FullName}

            $modelNames = @("regression_btree","regression_rf","regression_glm","regression_nn")
            foreach ($modelName in $modelNames) {
                Write-Host -ForeGroundColor 'magenta'("    Training Regression model: $modelName...")
                $query = "EXEC train_regression_model $modelName"
                ExecuteSQL $query
                Write-Host -ForeGroundColor 'magenta'("    Training Regression model: $modelName...Done!")
            }

            Write-Host -ForeGroundColor 'green' ("Step 3a Testing: Regression models")

            # test the binaryclass models and collect results and metrics
            Write-Host -ForeGroundColor 'magenta'("    Testing Regression models...")
            $models = "'regression_rf', 'regression_btree', 'regression_glm', 'regression_nn'"
            $query = "EXEC test_regression_models $models, '$connectionString'"
            ExecuteSQL $query
            Write-Host -ForeGroundColor 'magenta'("    Testing Regression models...Done!")
        }
        catch
        {
            Write-Host -ForegroundColor DarkYellow "Exception in training and testing regression models:"
            Write-Host -ForegroundColor Red $Error[0].Exception 
            throw
        }
    }
    ################################################################################
    # Create and execute the stored procedures for binary-class models
    ################################################################################
    Write-Host -ForeGroundColor 'green' ("Step 3b Training/Testing: Binary classification models")
    if($Prompt -ne 'N') {
        #Prompt user
        $ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
        if ($ans -eq 'E' -or $ans -eq 'e')
        {
            return
        }
    }
    else {
        #skip prompting since $Prompt -eq 'N' and set answer to 'y' to continue
        $ans = 'y'
    }
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
        try
        {
            # creat the stored procedure for binary class models
            Write-Host -ForeGroundColor 'magenta'("    Create and upload the stored procedures for training Binary classificaiton models...")
            $binaryclass = $scriptPath + "BinaryClassification/*_binaryclass_*.sql"
            Get-ChildItem $binaryclass | ForEach-Object -Process {ExecuteSQLScript -scriptFile $_.FullName}

            $modelNames = @("binaryclass_btree","binaryclass_rf","binaryclass_logit","binaryclass_nn")
            foreach ($modelName in $modelNames) {
                Write-Host -ForeGroundColor 'magenta'("    Training Binary classification model: $modelName...")
                $query = "EXEC train_binaryclass_model '$modelName'"
                ExecuteSQL $query
                Write-Host -ForeGroundColor 'magenta'("    Training Binary classification model: $modelName...Done!")
            }

            # test the binaryclass models and collect results and metrics
            Write-Host -ForeGroundColor 'magenta'("    Testing Binary classification models...")
            $models = "'binaryclass_rf', 'binaryclass_btree', 'binaryclass_logit', 'binaryclass_nn'"
            $query = "EXEC test_binaryclass_models $models, '$connectionString'"
            ExecuteSQL $query
            Write-Host -ForeGroundColor 'magenta'("    Testing Binary classification models...Done!")
        }
        catch
        {
            Write-Host -ForegroundColor DarkYellow "Exception in training and testing binary classification models:"
            Write-Host -ForegroundColor Red $Error[0].Exception 
            throw
        }
    }
    ##########################################################################
    # Create and execute the stored procedures for multi-class models
    ##########################################################################
    Write-Host -ForeGroundColor 'green' ("Step 3c Training: Multi-classification models")
    if($Prompt -ne 'N') {
        #Prompt user
        $ans = Read-Host 'Continue [y|Y], Exit [e|E], Skip [s|S]?'
        if ($ans -eq 'E' -or $ans -eq 'e')
        {
            return
        }
    }
    else {
        #skip prompting since $Prompt -eq 'N' and set answer to 'y' to continue
        $ans = 'y'
    }
    if ($ans -eq 'y' -or $ans -eq 'Y')
    {
        try
        {
            # Create the stored procedure for multi class models
            Write-Host -ForeGroundColor 'magenta'("    Create and upload the stored procedures for training Multi-classification models...")
            $multiclass = $scriptPath + "MultiClassification/*_multiclass_*.sql"
            Get-ChildItem $multiclass | ForEach-Object -Process {ExecuteSQLScript -scriptFile $_.FullName}

            $modelNames = @("multiclass_btree","multiclass_rf","multiclass_mn","multiclass_nn")
            foreach ($modelName in $modelNames) {
                Write-Host -ForeGroundColor 'magenta'("    Training Multi classification model: $modelName...")
                $query = "EXEC train_multiclass_model $modelName"
                ExecuteSQL $query
                Write-Host -ForeGroundColor 'magenta'("    Training Multi classification model: $modelName...Done!")
            }
            
            # test the multiclass models and collect results and metrics
            Write-Host -ForeGroundColor 'magenta'("    Testing Multi-classificaiton models...")
            $models = "'multiclass_rf', 'multiclass_btree', 'multiclass_nn', 'multiclass_mn'"
            $query = "EXEC test_multiclass_models $models, '$connectionString'"
            ExecuteSQL $query
            Write-Host -ForeGroundColor 'magenta'("    Testing Multi-classificaiton models...Done!")
            Write-Host -ForeGroundColor 'green'("Workflow finished successfully!")
        }
        catch
        {
            Write-Host -ForegroundColor DarkYellow "Exception in training and testing multiclass classification models:"
            Write-Host -ForegroundColor Red $Error[0].Exception 
        }
    }
    
    ##########################################################################
    # Score the maintenance data which is in SQL table PM_score
    ##########################################################################
        Write-Host -ForeGroundColor 'green'("Scoring maintenance data...")
        try
        {
		    # create score table
            Write-Host -ForeGroundColor 'green' ("Create SQL tables: PM_Score:")
            $script = $scriptPath + "DataProcessing\create_table_score.sql"
            ExecuteSQLScript $script
    
            # upload data to be scored to SQL table
            Write-Host -ForeGroundColor 'green' ("Populate SQL tables: PM_Score")
            $dataFile = "PM_Score"
            $destination = $SolutionData + $dataFile + ".csv"
            Write-Host -ForeGroundColor 'magenta'("    Populate SQL table: {0}..." -f $dataFile)
            $tableName = $DatabaseName + ".dbo." + $dataFile
            $tableSchema = $SolutionData + $dataFile + ".xml"
            ExecuteBCP("bcp $tableName format nul -c -x -f $tableSchema -t ','")
            
            Write-Host -ForeGroundColor 'magenta'("    Loading {0} to SQL table..." -f $dataFile)
            ExecuteBCP("bcp $tableName in $destination -F 2 -t ',' -f $tableSchema -C 'RAW' -b 20000")
		
            # execute the feature engineering for data to be scored
            Write-Host -ForeGroundColor 'magenta'("    Execute feature engineering for score dataset...")
		    #$script = $filePath + "FeatureEngineering/execute_feature_engineering_scoring.sql"
            $datasetType = 'score'
            $query = "EXEC feature_engineering $datasetType, '$connectionString'"
            ExecuteSQL $query

            # score the regression model and collect results
            Write-Host -ForeGroundColor 'magenta'("    Create and execute scoring with selected regression model...")
		    $script = $scriptPath + "Regression/score_regression_model.sql"
            ExecuteSQLScript $script
            #$script = $filePath + "Regression/execute_score_reg_model.sql"
            $model = 'regression_btree'
            $query = "EXEC score_regression_model $model, '$connectionString'"
            ExecuteSQL $query

            # score the binary classification model and collect results
            Write-Host -ForeGroundColor 'magenta'("    Create and execute scoring with selected binary classification model...")
		    $script = $scriptPath + "BinaryClassification/score_binaryclass_model.sql"
            ExecuteSQLScript $script
            #$script = $filePath + "BinaryClassification/execute_score_bclass_model.sql"
            $model = 'binaryclass_btree'
            $query = "EXEC score_binaryclass_model $model, '$connectionString'"
            ExecuteSQL $query

            # score the multi-class classification model and collect results
            Write-Host -ForeGroundColor 'magenta'("    Create and execute scoring with selected multi-class classification model...")
		    $script = $scriptPath + "MultiClassification/score_multiclass_model.sql"
            ExecuteSQLScript $script
            #$script = $filePath + "MultiClassification/execute_score_mclass_model.sql"
            $model = 'multiclass_btree'
            $query = "EXEC score_multiclass_model $model, '$connectionString'"
            ExecuteSQL $query

            Write-Host -ForeGroundColor 'green'("Scoring finished successfully!")
        }
        catch
        {
            Write-Host -ForegroundColor DarkYellow "Exception in scoring maintenance data:"
            Write-Host -ForegroundColor Red $Error[0].Exception 
        }

        WriteThanksMessage -SolutionName $SolutionName -servername $serverName -databaseName $DatabaseName -moreSolutionsURL $moreSolutionsURL

}
else {
    Write-Host ("To install this Solution you need to run Powershell as an Administrator. This program will close automatically in 20 seconds")
    Start-Sleep -s 20
    ## Close Powershell 
    Exit-PSHostProcess
    EXIT 
}