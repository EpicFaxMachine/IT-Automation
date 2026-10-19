@{
    AdDomain             = 'contoso.com'
    PrimaryMailDomain    = 'contoso.com'
    ContractorMailDomain = 'contractors.contoso.com'
    OnMicrosoftDomain    = 'contoso.mail.onmicrosoft.com'
    AdRootDn             = 'DC=contoso,DC=com'
    DomainUsersOu        = 'OU=Domain Users,DC=contoso,DC=com'
    ContractorOu         = 'OU=Contractors,OU=Domain Users,DC=contoso,DC=com'
    ContractorOktaOu     = 'OU=Okta Enabled,OU=Contractors,OU=Domain Users,DC=contoso,DC=com'
    ContractorO365Group  = 'Contractors-O365'
    ContractorsGroup     = 'Contractors'
    LogRoot              = 'C:\Scripts'
    OrgDisplayName       = 'Contoso'
    X400Org              = 'CONTOSO'
    X400Private          = 'CONTOSO'

    # Keys become the department dropdown. Add/remove freely.
    Departments = [ordered]@{
        'IT'          = @{ Dept = 'IT';          Desc = 'Information Technology'; Path = 'OU=Users,OU=IT,OU=Domain Users,DC=contoso,DC=com' }
        'HR'          = @{ Dept = 'HR';          Desc = 'Human Resources';         Path = 'OU=Users,OU=HR,OU=Domain Users,DC=contoso,DC=com' }
        'Finance'     = @{ Dept = 'Finance';     Desc = 'Finance';                 Path = 'OU=Users,OU=Finance,OU=Domain Users,DC=contoso,DC=com' }
        'Sales'       = @{ Dept = 'Sales';       Desc = 'Sales';                   Path = 'OU=Users,OU=Sales,OU=Domain Users,DC=contoso,DC=com' }
        'Operations'  = @{ Dept = 'Operations';  Desc = 'Operations';              Path = 'OU=Users,OU=Operations,OU=Domain Users,DC=contoso,DC=com' }
        'Contractors' = @{ Dept = 'Contractors'; Desc = 'Contractor';              Path = 'OU=Users,OU=Contractors,OU=Domain Users,DC=contoso,DC=com' }
    }
}
