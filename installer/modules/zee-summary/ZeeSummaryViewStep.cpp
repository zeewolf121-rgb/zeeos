/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "ZeeSummaryViewStep.h"

#include "Job.h"
#include "ViewManager.h"

CALAMARES_PLUGIN_FACTORY_DEFINITION( ZeeSummaryViewStepFactory, registerPlugin< ZeeSummaryViewStep >(); )

namespace
{
// Modules whose queued jobs write disks. Only partition does in our sequence; the ESP writes of
// zee-espbackup/zee-bootloader have no view step and are described as a fixed note in the QML.
const QStringList& diskModules()
{
    static const QStringList modules { QStringLiteral( "partition" ) };
    return modules;
}
}  // namespace

ZeeSummaryViewStep::ZeeSummaryViewStep( QObject* parent )
    : Calamares::QmlViewStep( parent )
    , m_config( new Config( this ) )
{
    connect( m_config, &Config::backupConfirmedChanged, this, [ this ] { emit nextStatusChanged( isNextEnabled() ); } );
    connect( m_config, &Config::disksChanged, this, [ this ] { emit nextStatusChanged( isNextEnabled() ); } );
}

QString
ZeeSummaryViewStep::prettyName() const
{
    return tr( "Summary" );
}

bool
ZeeSummaryViewStep::isNextEnabled() const
{
    return m_config->canInstall();
}

bool
ZeeSummaryViewStep::isBackEnabled() const
{
    return true;
}

bool
ZeeSummaryViewStep::isAtBeginning() const
{
    return true;
}

bool
ZeeSummaryViewStep::isAtEnd() const
{
    return true;
}

Calamares::JobList
ZeeSummaryViewStep::jobs() const
{
    return {};  // read-only page
}

QStringList
ZeeSummaryViewStep::plannedDiskJobs() const
{
    QStringList descriptions;
    for ( Calamares::ViewStep* step : Calamares::ViewManager::instance()->viewSteps() )
    {
        if ( step == this )
        {
            break;  // only what the pages before this one will do
        }
        if ( !diskModules().contains( step->moduleInstanceKey().module() ) )
        {
            continue;
        }
        for ( const Calamares::job_ptr& job : step->jobs() )
        {
            const QString d = job->prettyDescription();
            descriptions << ( d.isEmpty() ? job->prettyName() : d );
        }
    }
    return descriptions;
}

void
ZeeSummaryViewStep::onActivate()
{
    m_config->refresh( plannedDiskJobs() );
    Calamares::QmlViewStep::onActivate();
}

void
ZeeSummaryViewStep::setConfigurationMap( const QVariantMap& configurationMap )
{
    m_config->setConfigurationMap( configurationMap );
    Calamares::QmlViewStep::setConfigurationMap( configurationMap );
}
