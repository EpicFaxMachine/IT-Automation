@{
    DaysInactive         = 90
    OutputDir            = 'C:\Temp'
    OutputFileName       = 'InactiveUsers_90Days.xlsx'
    OktaDomain           = 'https://YOUR_ORG.okta.com'    # <OKTA_ORG_URL>
    OktaTokenEnvVar      = 'OKTA_API_TOKEN'
    AlternateMailDomains = @(
        'contoso.com'
        'contractors.contoso.com'
    )
}
