/* Author: test */
﻿USE [CDIO_MeditechDB]
GO
/****** Object:  StoredProcedure [dbo].[usp_Build_FCAP1A_PatientProvidedInfo_Extended]    Script Date: 7/13/2026 1:26:39 PM ******/
SET ANSI_NULLS ON
GO
SET QUOTED_IDENTIFIER ON
GO

/*
    Stored Procedure : dbo.usp_Build_FCAP1A_PatientProvidedInfo_Extended
    Purpose          : FCAP 1A PPI rebuild for Extended 10 percent cohort.
    Author           : Allan Z
    Version          : Extended
    Development Date : 2026-02-22
*/

ALTER   PROCEDURE [dbo].[usp_Build_FCAP1A_PatientProvidedInfo_Extended]
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @RunStart         DATETIME;
    DECLARE @RunEnd           DATETIME;
    DECLARE @DurationSeconds  INT;
    DECLARE @RecordCount      INT;
    DECLARE @WindowStart      DATE;
    DECLARE @WindowEnd        DATE;
    DECLARE @WindowEndNextDay DATE;

    SET @RunStart = SYSDATETIME();
    SET @RecordCount = 0;

    SET @WindowStart = '2022-11-05';
    SET @WindowEnd   = '2026-06-14';
    SET @WindowEndNextDay = DATEADD(DAY, 1, @WindowEnd);

    IF OBJECT_ID('dbo.FCAP1A_Cohort_Log','U') IS NULL
    BEGIN
        CREATE TABLE dbo.FCAP1A_Cohort_Log (
            LogID           INT IDENTITY(1,1) PRIMARY KEY,
            RunStart        DATETIME NOT NULL,
            RunEnd          DATETIME NULL,
            DurationSeconds INT NULL,
            RunStatus       VARCHAR(20) NOT NULL,
            DataTopic       NVARCHAR(100) NOT NULL,
            WindowStart     DATE NULL,
            WindowEnd       DATE NULL,
            TotalEligible   INT NULL,
            RecordCount     INT NULL,
            ProcessedBy     NVARCHAR(100) DEFAULT SYSTEM_USER,
            ErrorMessage    NVARCHAR(4000) NULL,
            Remarks         NVARCHAR(4000) NULL
        );
    END;

    IF OBJECT_ID('dbo.tbl_FCAP1A_PatientProvidedInfo_Extended','U') IS NOT NULL
        DROP TABLE dbo.tbl_FCAP1A_PatientProvidedInfo_Extended;

    CREATE TABLE dbo.tbl_FCAP1A_PatientProvidedInfo_Extended (
        PPI_ID            BIGINT IDENTITY(1,1) PRIMARY KEY,

        PatientID         NVARCHAR(50) NOT NULL,
        VisitID           NVARCHAR(255) NULL,

        PPIType           NVARCHAR(50) NOT NULL,
        PPIGroupID        NVARCHAR(255) NULL,
        AttributeName     NVARCHAR(100) NOT NULL,
        AttributeValue    NVARCHAR(4000) NULL,
        AttributeUnit     NVARCHAR(255) NULL,

        SourceTable       NVARCHAR(128) NOT NULL,
        SourceColumn      NVARCHAR(128) NULL,

        RowUpdateDateTime DATETIME NULL,
        ServiceDateTime   DATETIME NULL,

        ExtractedOn       DATETIME NOT NULL DEFAULT SYSDATETIME()
    );

    BEGIN TRY

        ;WITH

        PPI_CommPreferences AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('COMM_PREF' AS NVARCHAR(50)) AS PPIType,
                cp.CommunicationsPreferenceMethodID AS PPIGroupID,

                CAST('PreferredContactMethod' AS NVARCHAR(100)) AS AttributeName,
                CAST(cp.CommunicationsPreferenceMethodID AS NVARCHAR(4000)) AS AttributeValue,
                CAST(NULL AS NVARCHAR(255)) AS AttributeUnit,

                CAST('HimRec_CommPreferences' AS NVARCHAR(128)) AS SourceTable,
                CAST('CommunicationsPreferenceMethodID' AS NVARCHAR(128)) AS SourceColumn,

                cp.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_CommPreferences cp
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = cp.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE cp.RowUpdateDateTime IS NOT NULL
              AND cp.RowUpdateDateTime >= @WindowStart
              AND cp.RowUpdateDateTime <  @WindowEndNextDay
        ),

        PPI_HimRec_CustomQueries AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('HIM_QUERY_SINGLE' AS NVARCHAR(50)) AS PPIType,
                CAST(hq.QueryID AS NVARCHAR(255)) AS PPIGroupID,

                CAST(hq.QueryID AS NVARCHAR(100)) AS AttributeName,
                CAST(hq.QueryResponse AS NVARCHAR(4000)) AS AttributeValue,
                CAST(hq.QueryResponseAlternateUnit AS NVARCHAR(255)) AS AttributeUnit,

                CAST('HimRec_CustomDataQueries_Queries' AS NVARCHAR(128)) AS SourceTable,
                CAST('QueryResponse' AS NVARCHAR(128)) AS SourceColumn,

                hq.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_CustomDataQueries_Queries hq
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = hq.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE hq.RowUpdateDateTime IS NOT NULL
              AND hq.RowUpdateDateTime >= @WindowStart
              AND hq.RowUpdateDateTime <  @WindowEndNextDay
        ),

        PPI_HimRec_CustomQueriesMult AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('HIM_QUERY_MULTI' AS NVARCHAR(50)) AS PPIType,
                CAST(hm.QueryID AS NVARCHAR(255)) AS PPIGroupID,

                CAST(hm.QueryID AS NVARCHAR(100)) AS AttributeName,
                CAST(hm.QueryResponse AS NVARCHAR(4000)) AS AttributeValue,
                CAST(NULL AS NVARCHAR(255)) AS AttributeUnit,

                CAST('HimRec_CustomDataQueries_QueriesMult' AS NVARCHAR(128)) AS SourceTable,
                CAST('QueryResponse' AS NVARCHAR(128)) AS SourceColumn,

                hm.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_CustomDataQueries_QueriesMult hm
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = hm.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE hm.RowUpdateDateTime IS NOT NULL
              AND hm.RowUpdateDateTime >= @WindowStart
              AND hm.RowUpdateDateTime <  @WindowEndNextDay
        ),

        PPI_Employer AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('EMPLOYMENT' AS NVARCHAR(50)) AS PPIType,
                CAST(NULL AS NVARCHAR(255)) AS PPIGroupID,

                x.AttributeName,
                x.AttributeValue,
                x.AttributeUnit,

                CAST('HimRec_Employer' AS NVARCHAR(128)) AS SourceTable,
                x.SourceColumn,

                he.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_Employer he
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = he.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            CROSS APPLY (VALUES
                ('EmployerName',          CAST(he.Employer AS NVARCHAR(4000)),                          CAST(NULL AS NVARCHAR(255)), 'Employer'),
                ('EmployerAddress1',      CAST(he.EmployerAddress1 AS NVARCHAR(4000)),                  CAST(NULL AS NVARCHAR(255)), 'EmployerAddress1'),
                ('EmployerAddress2',      CAST(he.EmployerAddress2 AS NVARCHAR(4000)),                  CAST(NULL AS NVARCHAR(255)), 'EmployerAddress2'),
                ('EmployerCity',          CAST(he.EmployerCity AS NVARCHAR(4000)),                      CAST(NULL AS NVARCHAR(255)), 'EmployerCity'),
                ('EmployerState',         CAST(he.EmployerState_MisStateProvID AS NVARCHAR(4000)),      CAST(NULL AS NVARCHAR(255)), 'EmployerState_MisStateProvID'),
                ('EmployerZip',           CAST(he.EmployerZip AS NVARCHAR(4000)),                       CAST(NULL AS NVARCHAR(255)), 'EmployerZip'),
                ('EmployerCountry',       CAST(he.EmployerCountry_MisCntryID AS NVARCHAR(4000)),        CAST(NULL AS NVARCHAR(255)), 'EmployerCountry_MisCntryID'),
                ('EmployerPhone',         CAST(he.EmployerPhone AS NVARCHAR(4000)),                     CAST(NULL AS NVARCHAR(255)), 'EmployerPhone'),
                ('EmployerFacsimile',     CAST(he.EmployerFacsimile AS NVARCHAR(4000)),                 CAST(NULL AS NVARCHAR(255)), 'EmployerFacsimile'),
                ('EmployerEmail',         CAST(he.EmployerEmail AS NVARCHAR(4000)),                     CAST(NULL AS NVARCHAR(255)), 'EmployerEmail'),
                ('EmployerOccupation',    CAST(he.EmployerOccupation AS NVARCHAR(4000)),                CAST(NULL AS NVARCHAR(255)), 'EmployerOccupation'),
                ('EmploymentStatus',      CAST(he.EmployerEmploymentStatus_MisEmpStatusID AS NVARCHAR(4000)), CAST(NULL AS NVARCHAR(255)), 'EmployerEmploymentStatus_MisEmpStatusID'),
                ('EmployeeIdentifier',    CAST(he.EmployeeIdentifier AS NVARCHAR(4000)),                CAST(NULL AS NVARCHAR(255)), 'EmployeeIdentifier')
            ) AS x(AttributeName, AttributeValue, AttributeUnit, SourceColumn)
            WHERE he.RowUpdateDateTime IS NOT NULL
              AND he.RowUpdateDateTime >= @WindowStart
              AND he.RowUpdateDateTime <  @WindowEndNextDay
              AND x.AttributeValue IS NOT NULL
        ),

        PPI_PersContAuth AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('PERSONAL_CONTACT_AUTH' AS NVARCHAR(50)) AS PPIType,
                CAST(pca.PersonalContactType_MisContactTypeID AS NVARCHAR(255)) AS PPIGroupID,

                x.AttributeName,
                x.AttributeValue,
                x.AttributeUnit,

                CAST('HimRec_PersContAuth' AS NVARCHAR(128)) AS SourceTable,
                x.SourceColumn,

                pca.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_PersContAuth pca
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = pca.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            CROSS APPLY (VALUES
                ('DisclosureAuthorization',             CAST(pca.DisclosureAuthorization AS NVARCHAR(4000)),             CAST(NULL AS NVARCHAR(255)), 'DisclosureAuthorization'),
                ('AppointmentDisclosureAuthorization',  CAST(pca.AppointmentDisclosureAuthorization AS NVARCHAR(4000)),  CAST(NULL AS NVARCHAR(255)), 'AppointmentDisclosureAuthorization'),
                ('ClinicalDisclosureAuthorization',     CAST(pca.ClinicalDisclosureAuthorization AS NVARCHAR(4000)),     CAST(NULL AS NVARCHAR(255)), 'ClinicalDisclosureAuthorization'),
                ('FinancialDisclosureAuthorization',    CAST(pca.FinancialDisclosureAuthorization AS NVARCHAR(4000)),    CAST(NULL AS NVARCHAR(255)), 'FinancialDisclosureAuthorization')
            ) AS x(AttributeName, AttributeValue, AttributeUnit, SourceColumn)
            WHERE pca.RowUpdateDateTime IS NOT NULL
              AND pca.RowUpdateDateTime >= @WindowStart
              AND pca.RowUpdateDateTime <  @WindowEndNextDay
              AND x.AttributeValue IS NOT NULL
        ),

        PPI_PersContPhones AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('PERSONAL_CONTACT_PHONE' AS NVARCHAR(50)) AS PPIType,
                CAST(ppn.PersonalContactType_MisContactTypeID AS NVARCHAR(255)) AS PPIGroupID,

                CAST('PersonalContactPhone' AS NVARCHAR(100)) AS AttributeName,
                CAST(ppn.PersonalContactPhoneNumberID AS NVARCHAR(4000)) AS AttributeValue,
                CAST(ppn.PersonalContactPhoneType_MisPhNumTypeID AS NVARCHAR(255)) AS AttributeUnit,

                CAST('HimRec_PersContPhoneNumbers' AS NVARCHAR(128)) AS SourceTable,
                CAST('PersonalContactPhoneNumberID' AS NVARCHAR(128)) AS SourceColumn,

                ppn.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_PersContPhoneNumbers ppn
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = ppn.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE ppn.RowUpdateDateTime IS NOT NULL
              AND ppn.RowUpdateDateTime >= @WindowStart
              AND ppn.RowUpdateDateTime <  @WindowEndNextDay
              AND ppn.PersonalContactPhoneNumberID IS NOT NULL
        ),

        PPI_PersonalContacts AS (
            SELECT
                c.PatientID,
                CAST(NULL AS NVARCHAR(255)) AS VisitID,

                CAST('PERSONAL_CONTACT' AS NVARCHAR(50)) AS PPIType,
                CAST(pc.PersonalContactType_MisContactTypeID AS NVARCHAR(255)) AS PPIGroupID,

                x.AttributeName,
                x.AttributeValue,
                x.AttributeUnit,

                CAST('HimRec_PersonalContacts' AS NVARCHAR(128)) AS SourceTable,
                x.SourceColumn,

                pc.RowUpdateDateTime,
                CAST(NULL AS DATETIME) AS ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_PersonalContacts pc
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = pc.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            CROSS APPLY (VALUES
                ('PersonalContactNameLast',       CAST(pc.PersonalContactNameLast AS NVARCHAR(4000)),       CAST(NULL AS NVARCHAR(255)), 'PersonalContactNameLast'),
                ('PersonalContactNameFirst',      CAST(pc.PersonalContactNameFirst AS NVARCHAR(4000)),      CAST(NULL AS NVARCHAR(255)), 'PersonalContactNameFirst'),
                ('PersonalContactNameMiddle',     CAST(pc.PersonalContactNameMiddle AS NVARCHAR(4000)),     CAST(NULL AS NVARCHAR(255)), 'PersonalContactNameMiddle'),
                ('PersonalContactAddress1',       CAST(pc.PersonalContactAddress1 AS NVARCHAR(4000)),       CAST(NULL AS NVARCHAR(255)), 'PersonalContactAddress1'),
                ('PersonalContactAddress2',       CAST(pc.PersonalContactAddress2 AS NVARCHAR(4000)),       CAST(NULL AS NVARCHAR(255)), 'PersonalContactAddress2'),
                ('PersonalContactCity',           CAST(pc.PersonalContactCity AS NVARCHAR(4000)),           CAST(NULL AS NVARCHAR(255)), 'PersonalContactCity'),
                ('PersonalContactState',          CAST(pc.PersonalContactState_MisStateProvID AS NVARCHAR(4000)), CAST(NULL AS NVARCHAR(255)), 'PersonalContactState_MisStateProvID'),
                ('PersonalContactZip',            CAST(pc.PersonalContactZip AS NVARCHAR(4000)),            CAST(NULL AS NVARCHAR(255)), 'PersonalContactZip'),
                ('PersonalContactCountry',        CAST(pc.PersonalContactCountry_MisCntryID AS NVARCHAR(4000)), CAST(NULL AS NVARCHAR(255)), 'PersonalContactCountry_MisCntryID'),
                ('PersonalContactEmail',          CAST(pc.PersonalContactEmail AS NVARCHAR(4000)),          CAST(NULL AS NVARCHAR(255)), 'PersonalContactEmail'),
                ('PersonalContactLanguage',       CAST(pc.PersonalContactLanguage_MisLangID AS NVARCHAR(4000)), CAST(NULL AS NVARCHAR(255)), 'PersonalContactLanguage_MisLangID'),
                ('PersonalContactRelationship',   CAST(pc.PersonalContactRelationship_MisRelatID AS NVARCHAR(4000)), CAST(NULL AS NVARCHAR(255)), 'PersonalContactRelationship_MisRelatID')
            ) AS x(AttributeName, AttributeValue, AttributeUnit, SourceColumn)
            WHERE pc.RowUpdateDateTime IS NOT NULL
              AND pc.RowUpdateDateTime >= @WindowStart
              AND pc.RowUpdateDateTime <  @WindowEndNextDay
              AND x.AttributeValue IS NOT NULL
        ),

        PPI_VisitContactAuth AS (
            SELECT
                c.PatientID,
                v.VisitID,

                CAST('VISIT_CONTACT_AUTH' AS NVARCHAR(50)) AS PPIType,
                CAST(vca.VisitPersonalContactType_MisContactTypeID AS NVARCHAR(255)) AS PPIGroupID,

                x.AttributeName,
                x.AttributeValue,
                x.AttributeUnit,

                CAST('HimRec_VisitContactAuth' AS NVARCHAR(128)) AS SourceTable,
                x.SourceColumn,

                vca.RowUpdateDateTime,
                v.ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.HimRec_VisitContactAuth vca
                ON v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = vca.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            CROSS APPLY (VALUES
                ('VisitDisclosureAuthorization',            CAST(vca.VisitDisclosureAuthorization AS NVARCHAR(4000)),            CAST(NULL AS NVARCHAR(255)), 'VisitDisclosureAuthorization'),
                ('VisitAppointmentDisclosureAuthorization', CAST(vca.VisitAppointmentDisclosureAuthorization AS NVARCHAR(4000)), CAST(NULL AS NVARCHAR(255)), 'VisitAppointmentDisclosureAuthorization'),
                ('VisitClinicalDisclosureAuthorization',    CAST(vca.VisitClinicalDisclosureAuthorization AS NVARCHAR(4000)),    CAST(NULL AS NVARCHAR(255)), 'VisitClinicalDisclosureAuthorization'),
                ('VisitFinancialDisclosureAuthorization',   CAST(vca.VisitFinancialDisclosureAuthorization AS NVARCHAR(4000)),   CAST(NULL AS NVARCHAR(255)), 'VisitFinancialDisclosureAuthorization')
            ) AS x(AttributeName, AttributeValue, AttributeUnit, SourceColumn)
            WHERE v.ServiceDateTime IS NOT NULL
              AND v.ServiceDateTime >= @WindowStart
              AND v.ServiceDateTime <  @WindowEndNextDay
              AND x.AttributeValue IS NOT NULL
        ),

        PPI_RegAcct_CustomQueries AS (
            SELECT
                c.PatientID,
                v.VisitID,

                CAST('REG_QUERY_SINGLE' AS NVARCHAR(50)) AS PPIType,
                CAST(ra.QueryID AS NVARCHAR(255)) AS PPIGroupID,

                CAST(ra.QueryID AS NVARCHAR(100)) AS AttributeName,
                CAST(ra.QueryResponse AS NVARCHAR(4000)) AS AttributeValue,
                CAST(ra.QueryResponseAlternateUnit AS NVARCHAR(255)) AS AttributeUnit,

                CAST('RegAcct_CustomDataQueries_Queries' AS NVARCHAR(128)) AS SourceTable,
                CAST('QueryResponse' AS NVARCHAR(128)) AS SourceColumn,

                ra.RowUpdateDateTime,
                v.ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_CustomDataQueries_Queries ra
                ON v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = ra.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE v.ServiceDateTime IS NOT NULL
              AND v.ServiceDateTime >= @WindowStart
              AND v.ServiceDateTime <  @WindowEndNextDay
        ),

        PPI_RegAcct_CustomQueriesMult AS (
            SELECT
                c.PatientID,
                v.VisitID,

                CAST('REG_QUERY_MULTI' AS NVARCHAR(50)) AS PPIType,
                CAST(rm.QueryID AS NVARCHAR(255)) AS PPIGroupID,

                CAST(rm.QueryID AS NVARCHAR(100)) AS AttributeName,
                CAST(rm.QueryResponse AS NVARCHAR(4000)) AS AttributeValue,
                CAST(NULL AS NVARCHAR(255)) AS AttributeUnit,

                CAST('RegAcct_CustomDataQueries_QueriesMult' AS NVARCHAR(128)) AS SourceTable,
                CAST('QueryResponse' AS NVARCHAR(128)) AS SourceColumn,

                rm.RowUpdateDateTime,
                v.ServiceDateTime
            FROM dbo.tbl_FCAP1A_Cohort10_Extended c
            INNER JOIN [NBIDRSRV2].[AKULivendb].dbo.AdmVisits v
                ON c.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = v.PatientID COLLATE SQL_Latin1_General_CP1_CI_AS
            INNER JOIN [NBIDRSRV2].[AKULiveATdb].dbo.RegAcct_CustomDataQueries_QueriesMult rm
                ON v.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
                 = rm.VisitID COLLATE SQL_Latin1_General_CP1_CI_AS
            WHERE v.ServiceDateTime IS NOT NULL
              AND v.ServiceDateTime >= @WindowStart
              AND v.ServiceDateTime <  @WindowEndNextDay
        ),

        PPI_All AS (
            SELECT * FROM PPI_CommPreferences
            UNION ALL SELECT * FROM PPI_HimRec_CustomQueries
            UNION ALL SELECT * FROM PPI_HimRec_CustomQueriesMult
            UNION ALL SELECT * FROM PPI_Employer
            UNION ALL SELECT * FROM PPI_PersContAuth
            UNION ALL SELECT * FROM PPI_PersContPhones
            UNION ALL SELECT * FROM PPI_PersonalContacts
            UNION ALL SELECT * FROM PPI_VisitContactAuth
            UNION ALL SELECT * FROM PPI_RegAcct_CustomQueries
            UNION ALL SELECT * FROM PPI_RegAcct_CustomQueriesMult
        )

        INSERT INTO dbo.tbl_FCAP1A_PatientProvidedInfo_Extended (
            PatientID,
            VisitID,
            PPIType,
            PPIGroupID,
            AttributeName,
            AttributeValue,
            AttributeUnit,
            SourceTable,
            SourceColumn,
            RowUpdateDateTime,
            ServiceDateTime,
            ExtractedOn
        )
        SELECT DISTINCT
            a.PatientID,
            a.VisitID,
            a.PPIType,
            a.PPIGroupID,
            a.AttributeName,
            a.AttributeValue,
            a.AttributeUnit,
            a.SourceTable,
            a.SourceColumn,
            a.RowUpdateDateTime,
            a.ServiceDateTime,
            SYSDATETIME()
        FROM PPI_All a;

        SELECT @RecordCount = COUNT(*) FROM dbo.tbl_FCAP1A_PatientProvidedInfo_Extended;

        SET @RunEnd = SYSDATETIME();
        SET @DurationSeconds = DATEDIFF(SECOND, @RunStart, @RunEnd);

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            DurationSeconds,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            RecordCount,
            ProcessedBy,
            Remarks
        )
        VALUES (
            @RunStart,
            @RunEnd,
            @DurationSeconds,
            'SUCCESS',
            'PatientProvidedInfo_Extended',
            @WindowStart,
            @WindowEnd,
            @RecordCount,
            SYSTEM_USER,
            'Patient Provided Information (PPI) rebuild completed successfully.'
        );

    END TRY
    BEGIN CATCH

        INSERT INTO dbo.FCAP1A_Cohort_Log (
            RunStart,
            RunEnd,
            RunStatus,
            DataTopic,
            WindowStart,
            WindowEnd,
            ProcessedBy,
            ErrorMessage,
            Remarks
        )
        VALUES (
            @RunStart,
            SYSDATETIME(),
            'FAILED',
            'PatientProvidedInfo_Extended',
            @WindowStart,
            @WindowEnd,
            SYSTEM_USER,
            ERROR_MESSAGE(),
            'Error during Patient Provided Information (PPI) rebuild.'
        );

        THROW;
    END CATCH;
END;
