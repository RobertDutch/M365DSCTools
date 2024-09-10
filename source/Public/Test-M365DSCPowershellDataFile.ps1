Function Test-M365DSCPowershellDataFile {
    <#
    .Synopsis
    Tests the specified object against the information defined in the ExampleData
    from the M365DSC.CompositeResources module.

    .Description
    This function tests the specified object against the information defined in the
    ExampleData from the M365DSC.CompositeResources module. It creates a Pester test
    to check if the specified data and types are correct, as specified in the example
    data.

    .Parameter InputObject
    The object that contains the data object that needs to be tested.

    .Parameter MandatoryObject
    The object that contains the Mandatory data.

    .Parameter MandatoryAction
    Action Type for test Mandatory 'Present', 'Absent'

    .Parameter excludeAvailableAsResource
    All items that are available as a resource and have to be ignored.  ( wildcards can be uses )

    .Parameter excludeRequired
    Required items have to be ignored. ( no wildcards )

    .Parameter Verbosity
    Specifies the verbosity level of the output. Allowed values are:
    None', 'Detailed', 'Diagnostic'. Default is 'Detailed'.

    .Parameter StackTraceVerbosity
    Specifies the verbosity level of the output. Allowed values are:
    'None', 'FirstLine', 'Filtered', 'Full'. Default is 'Firstline'.

    .Parameter pesterShowScript
    If specified, the generated Pester script will be opened in an editor.

    .Parameter pesterOutputObject
    If specified, the executed Pester script result will returned.

    .Example
    $InputObject = Import-PSDataFile -path '%Filename%.psd'

    Test-M365DSCPowershellDataFile -InputObject $InputObject `
    -excludeAvailableAsResource *CimInstance, *UniqueID, *IsSingleInstance `
    -excludeRequired CimInstance, UniqueID `
    -pesterShowScript

    .Example
    $InputObject = Import-PSDataFile -path '%Filename_InputObject%.psd1'
    $MandatoryObject = Import-PSDataFile -path '$Filename_MandatoryObject%.psd1'


    Test-M365DSCPowershellDataFile -InputObject $InputObject `
    -MandatoryObject $MandatoryObject `
    -MandatoryAction Present `
    -excludeAvailableAsResource *CimInstance, *UniqueID, *IsSingleInstance `
    -excludeRequired CimInstance, UniqueID `
    -pesterShowScript


    .NOTES
    This function requires Modules: M365DSC.CompositeResources, ObjectGraphTools
    #>

    [CmdletBinding()]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '', Justification = 'Bug powershell, Vars are declared')]

    param (
        [Parameter(Mandatory = $True)]
        [System.Object]$InputObject,

        [Parameter(Mandatory = $False )]
        [System.Object]$MandatoryObject,

        [Parameter(Mandatory = $False )][ValidateSet('Present', 'Absent')]
        [string]$MandatoryAction,

        [Parameter(Mandatory = $False)]
        [String[]]$excludeAvailableAsResource,

        [Parameter(Mandatory = $False)]
        [String[]]$excludeRequired,

        [Parameter(Mandatory = $False)]
        [Switch]$Ignore_AllRequired,

        [Parameter(Mandatory = $False)][ValidateSet('None', 'Detailed', 'Diagnostic')]
        [String]$pesterVerbosity = 'Detailed',

        [Parameter(Mandatory = $False)][ValidateSet('None', 'FirstLine', 'Filtered', 'Full')]
        [String]$pesterStackTraceVerbosity = 'FirstLine',

        [Parameter(Mandatory = $False)]
        [Switch]$pesterShowScript,

        [Parameter(Mandatory = $False)]
        [Switch]$pesterOutputObjectt
    )

    begin {

        # Function to display elapsed and total time
        function ShowElapsed {
            param( [Switch]$reset )
            if ($reset) { $script:totalTime = Get-Date; $script:elapsedTime = Get-Date }
            if (-not $script:totalTime ) { $script:totalTime = Get-Date }
            if (-not $script:elapsedTime ) { $script:elapsedTime = Get-Date }
            $result = '^ Elapsed: {0} TotalTime: {1} seconds' -f "$(($(Get-Date) - $elapsedTime).TotalSeconds) Seconds".PadRight(30, ' ') , ($(Get-Date) - $totalTime).TotalSeconds
            $script:elapsedTime = Get-Date
            return $result
        }
        # Function to test if a string is a valid GUID
        function Test-IsGuid {
            [CmdletBinding()][OutputType([bool])]
            param([Parameter(Mandatory = $true, ValueFromPipeline = $True)][string]$stringGuid)
            process {
                try {
                    $objectGuid = [System.Guid]::Empty
                    return [System.Guid]::TryParse($stringGuid, [ref]$objectGuid)
                }
                catch {
                    Write-Error "An error occurred while checking the GUID format: $_"
                    return $false
                }
            }
        }

        # Function to generate Pester "should" commands based on type
        function Pester_Type_Should_Command {
            [CmdletBinding()][OutputType([System.String])]
            param([Parameter(Mandatory = $true)][string]$type)
            try {
                switch ($type) {
                    'SInt32' { return "should -match '^\d+$' -because 'Must be a positive Integer'" }
                    'SInt64' { return "should -match '^\d+$' -because 'Must be a positive Integer'" }
                    'UInt32' { return "should -BeOfType 'Int'" }
                    'UInt64' { return "should -BeOfType 'Int'" }
                    'Guid' { return "Test-IsGuid | should -Be 'True'" }
                    default { return "should -BeOfType '$type'" }
                }
            }
            catch {
                Write-Error "An error occurred while generating Pester 'should' assertion: $_"
                return $null
            }
        }

        # Class M365DSC reference values
        Class M365DSC_Reference_Values {
            [string]$type
            [string]$required
            [String]$description
            [String]$validateSet

            M365DSC_Reference_Values([string]$inputString) {
                [array]$result = $inputString.split('|').foreach{ $_.trim() }
                $this.type = $result[0]
                $this.required = $result[1]
                $this.description = $result[2]
                $this.validateSet = $result[3].foreach{ "'" + ($result[3] -Replace '\s*\/\s*', "', '") + "'" }
            }
        }

        Function Create_Pesternodes_Mandatory {
            param ( [psnode]$MandatoryObject )
            $MandatoryLeafs = $MandatoryObject | get-childnode -Recurse -Leaf
            $MandatoryLeafs.foreach{
                if ( $MandatoryAction -eq 'Absent'){
                    "`$inputObject.{0} | should -BeNullOrEmpty -because 'Denied Mandatory Setting'" -f $_.Path
                }
                else {
                    "`$inputObject.{0} | should -Be {1} -Because 'Mandatory Setting'" -f $_.Path, $_.Value
                }
            }
        }

        Function Create_PesterNode {
            param (
                [psnode]$nodeObject,
                [switch]$recursive
            )

            $refNodePath = '{0}' -f $($nodeObject.Path) -replace '\[\d+\]', '[0]'
            $objRefNode = $ht[$refNodePath]

            # Exclude nodes that match the patterns defined in $excludeAvailableAsResource
            foreach ($Exclude in  $excludeAvailableAsResource) {
                if (  $nodeObject.Path -like $Exclude ) {
                    "#`$inputObject.{0}" -f $nodeObject.Path
                    return
                }
            }

            # No Composite Resource available
            if ( $null -eq $objRefNode ) {
                "`$inputObject.{0} | should -BeNullOrEmpty -because 'Not available as Composite Resource'" -f $nodeObject.Path
                return
            }

            if ( $nodeObject -is [psCollectionNode] ) {

                # Check Folder Type
                [Bool]$isHashTable = $( $objRefNode.valueType.name -eq 'HashTable')
                if ($isHashTable) {
                    "`$inputObject.{0} -is [HashTable] | should -BeTrue" -f $nodeObject.Path
                }
                else {
                    "`$inputObject.{0} -is [Array] | should -BeTrue " -f $nodeObject.Path
                }

                # Check for required
                if (-not $Ignore_AllRequired) {
                    $objRequiredNodes = $htRequired["$($refNodePath)"]
                    if ($objRequiredNodes) {
                        foreach ( $objRequiredNode in $objRequiredNodes ) {
                            if ($objRequiredNode.name -notin $excludeRequired ) {
                                "`$inputObject.{0}.{1} | should -not -BeNullOrEmpty -Because 'Required setting'" -f $nodeObject.path, $objRequiredNode.name
                            }
                            else {
                                "#`$inputObject.{0}.{1} | should -not -BeNullOrEmpty -Because 'Required setting'" -f $nodeObject.path, $objRequiredNode.name
                            }
                        }
                    }
                }

                # Recursively process child nodes if exsists
                $childs = $nodeObject | Get-ChildNode
                Foreach ($node in $childs) {
                    if ($recursive) { Create_PesterNode -nodeObject $node -recursive }
                }

            }
            else {
                # LeafNode
                $objRefNodeValue = [M365DSC_Reference_Values]::new($objRefNode.Value)
                # Type Validation
                if ( $objRefNodeValue.type ) { "`$inputObject.{0} | {1}" -f $nodeObject.path , $(Pester_Type_Should_Command $objRefNodeValue.type) }
                # ValidationSet Validation
                if ( $objRefNodeValue.validateSet ) { "`$inputObject.{0} | should -beIn {1}" -f $nodeObject.path, $objRefNodeValue.validateSet }
            }
        }
    }
    process {

        if (($MandatoryObject -and -not $MandatoryAction) -or ($MandatoryAction -and -not $MandatoryObject)) {
            throw "If parameter MandatoryObject is used, MandatoryAction is to be set and vice versa."
        }

        ShowElapsed -Reset | Out-Null
        'Load Example data from module M365DSC.CompositeResources' | Write-Log
        Switch (Get-Module M365DSC.CompositeResources) {
            { $_.Name -eq 'M365DSC.CompositeResources' } { $objM365DataExample = Import-PSDataFile -Path ((((Get-Module M365DSC.CompositeResources)).path | Split-Path) + '\M365ConfigurationDataExample.psd1') }
            Default { $objM365DataExample = Import-PSDataFile -Path (((Get-Module -ListAvailable M365DSC.CompositeResources).path | Split-Path) + '\M365ConfigurationDataExample.psd1') }
        }
        ShowElapsed | Write-Log -Debug

        'Create Hashtables for reference data ' | Write-Log
        [hashtable]$ht = @{}
        [hashtable]$htRequired = @{}
        $nodeObject = $inputObject | Get-ChildNode
        foreach ($node in $nodeObject) {
            foreach ($node in $($node | Get-ChildNode)) {
                # Create Hashtabel Exampledata
                $objM365DataExample | Get-node("$($node.path)") | Get-ChildNode -Recurse -IncludeSelf | ForEach-Object {
                    $ht["$($_.path)"] = $_
                    # Create HashTable Required
                    if (-not $Ignore_AllRequired) {
                        if ($_ -is [PSLeafnode]) {
                            if ($_.value -match '\| Required \|') {
                                $parentPath = $_.parentnode.path.ToString()
                                if (-not $htRequired.Contains("$parentPath")  ) {
                                    $htRequired["$parentPath"] = [System.Collections.Generic.List[psnode]]::new()
                                }
                                $htRequired["$parentPath"].add( $_ )
                            }
                        }
                    }
                }
            }
        }

        ShowElapsed | Write-Log -Debug


        'Create pester rules' | Write-Log

        $pesterConfig = @(
            '#Requires -Modules Pester'
            'Describe ''--- Check M365-DSC-CompositeResources configuration ---'' {'
            '  Context ''AllNodes'' {'

            '  }'
            '  Context ''NonNodeData'' {'
            foreach ($workload in ( $inputObject | get-node 'NonNodeData' | get-childnode )) {
                '    Context ''{0}'' {{' -f $workload.Path
                '      It ''{0}'' {{' -f $workload.Path
                Create_PesterNode -nodeObject $workload | ForEach-Object { '        {0}' -f $_ }
                '      }'
                If ($workload -is [psCollectionNode] ) {
                    foreach ($workloadFolder in ($workload | get-childnode )) {
                        '      It ''{0}'' {{' -f $workloadFolder.Path
                        Create_PesterNode -nodeObject $workloadFolder -recursive | ForEach-Object { '        {0}' -f $_ }
                        '      }'
                    }
                }
                '    }'
            }
            '  }'
            if ($MandatoryObject) {
                '  Context ''Mandatory'' {'
                '      It ''Mandatory'' {'
                Create_Pesternodes_Mandatory -MandatoryObject $($MandatoryObject | get-node) | ForEach-Object { '        {0}' -f $_ }
                '    }'
                '  }'
            }
            '}'
        )

        ShowElapsed | Write-Log -Debug

        # Remove empty lines from the $pesterConfig variable
        $pesterConfig = $pesterConfig | Where-Object { $_.Trim() -ne '' }

        try {
            # Ensure that $pesterConfig is defined before continuing
            if (-not $pesterConfig) { throw "The variable `\$pesterConfig` is not defined." }

            # Create a temporary Pester script file for test execution
            $pesterScriptPath = [System.IO.Path]::ChangeExtension((New-TemporaryFile).FullName, '.tests.ps1')
            $pesterConfig | Out-File -FilePath $pesterScriptPath -Force -Confirm:$false -Encoding ascii

            # Open the generated Pester script in Visual Studio Code
            if ($pesterShowScript) { psedit $pesterScriptPath }

            # Set parameters for the Pester container that manages the test execution
            $pesterParams = [ordered]@{ Path = $pesterScriptPath }
            $pesterContainer = New-PesterContainer @pesterParams

            # Execute the Pester tests and store the results in the $pesterResult variable
            $pesterConfiguration = [PesterConfiguration]@{
                Run    = @{ Container = $pesterContainer; PassThru = $true }
                Should = @{ ErrorAction = 'Continue' }
                Output = @{ Verbosity = $pesterVerbosity ; StackTraceVerbosity = $pesterStackTraceVerbosity }
            }

            # Execute Pester tests and store results
            'Execute pesterscript' | Write-Log
            $pesterResult = Invoke-Pester -Configuration $pesterConfiguration
            if ($pesterOutputObjectt) {
                return $pesterResult
            }

        }
        catch {
            Write-Error "An error occurred: $_"
        }
        finally {
            # Remove the temporary Pester script file after the tests have been executed
            if (Test-Path -Path $pesterScriptPath) {
                Remove-Item -Path $pesterScriptPath -Force -ErrorAction SilentlyContinue
            }

            ShowElapsed | Write-Log -Verbose
            # Log the test results, with failure handling if any tests have failed
            if ( $pesterResult.FailedCount -gt 0) { $splat = @{ Failure = $true } } else { $splat = @{} }
            'Pester[{0}]  Tests:{1}  Passed:{2}  Failed:{3} ' -f $pesterResult.version, $pesterResult.TotalCount, $pesterResult.PassedCount, $pesterResult.FailedCount | Write-Log @splat
        }

        ShowElapsed | Write-Log -Debug
    }

}
