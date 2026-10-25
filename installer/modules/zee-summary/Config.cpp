/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "Config.h"

#include "DiskPlan.h"

#include <string>
#include <vector>

Config::Config( QObject* parent )
    : QObject( parent )
{
}

void
Config::setConfigurationMap( const QVariantMap& map )
{
    // Same shape as Calamares presets elsewhere:
    //   presets: { backupConfirmed: { value: true, editable: false } }
    // Only the unattended test preset (P4-9) sets this; the shipped config leaves it unset.
    const QVariantMap preset = map.value( QStringLiteral( "presets" ) )
                                   .toMap()
                                   .value( QStringLiteral( "backupConfirmed" ) )
                                   .toMap();
    m_presetConfirmed = preset.value( QStringLiteral( "value" ), false ).toBool();
    m_backupEditable = preset.value( QStringLiteral( "editable" ), true ).toBool();
    setBackupConfirmed( m_presetConfirmed );
}

void
Config::setBackupConfirmed( bool confirmed )
{
    if ( !m_backupEditable )
    {
        confirmed = m_presetConfirmed;
    }
    if ( confirmed != m_backupConfirmed )
    {
        m_backupConfirmed = confirmed;
        emit backupConfirmedChanged( confirmed );
    }
}

void
Config::refresh( const QStringList& jobDescriptions )
{
    std::vector< std::string > descriptions;
    descriptions.reserve( jobDescriptions.size() );
    for ( const QString& d : jobDescriptions )
    {
        descriptions.push_back( d.toStdString() );
    }

    QVariantList disks;
    for ( const ZeeSummary::DiskChanges& group : ZeeSummary::groupByDisk( descriptions ) )
    {
        QStringList changes;
        for ( const std::string& c : group.changes )
        {
            changes << QString::fromStdString( c );
        }
        disks << QVariantMap { { QStringLiteral( "disk" ), QString::fromStdString( group.disk ) },
                               { QStringLiteral( "changes" ), changes } };
    }
    m_disks = disks;
    emit disksChanged();

    // Every visit asks again: going back and changing the layout must not keep an old "yes".
    m_backupConfirmed = !m_presetConfirmed;  // force the signal below
    setBackupConfirmed( m_presetConfirmed );
}
