@{
    Domain            = 'contoso.com'
    AdRootDn          = 'DC=contoso,DC=com'
    AdminUser         = 'CONTOSO\administrator'
    PasswordFile      = 'C:\Windows\powershellSession.txt'
    OktaDomain        = 'https://YOUR_ORG.okta.com'   # <OKTA_ORG_URL>
    OktaTokenEnvVar   = 'OKTA_API_TOKEN'
    OktaTokenFile     = 'C:\Scripts\Offboarding\okta_token.txt'
    AzureSyncServer   = 'AADSYNC01'
    DomainController  = 'DC01.contoso.com'
    DisabledUsersOU   = 'OU=Disabled Users,DC=contoso,DC=com'
    EvaultGroup       = 'Journal-FormerEmployees-DeleteAllEmails'
    GroupExportPath   = 'C:\Scripts\Offboarding\UserGroups'
    TerminatedCsv     = 'C:\Scripts\Offboarding\TerminatedUsers.csv'
    TranscriptLog     = 'C:\Scripts\Offboarding\ScriptLogs.txt'
    PrimaryMailDomain = 'contoso.com'

    # OFF by default — set Enabled = $true to allow the GUI checkbox to send mail
    TicketEmail = @{
        Enabled    = $false
        To         = 'helpdesk@contoso.com'
        From       = 'offboarding@contoso.com'
        SmtpServer = 'smtp.contoso.com'
        SubjectTpl = '{0} Offboarding Tasks'
    }

    GraphScopes = @(
        'User.Read.All'
        'Organization.Read.All'
        'Directory.ReadWrite.All'
    )
}
