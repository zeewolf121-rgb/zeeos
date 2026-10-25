/* SPDX-License-Identifier: GPL-3.0-or-later */
#include "DiskPlan.h"

#include <cctype>

namespace ZeeSummary
{

namespace
{
bool
isDigit( char c )
{
    return std::isdigit( static_cast< unsigned char >( c ) ) != 0;
}

bool
startsWith( const std::string& s, const std::string& prefix )
{
    return s.compare( 0, prefix.size(), prefix ) == 0;
}

void
replaceAll( std::string& s, const std::string& from, const std::string& to )
{
    for ( std::size_t pos = s.find( from ); pos != std::string::npos; pos = s.find( from, pos + to.size() ) )
    {
        s.replace( pos, from.size(), to );
    }
}

std::string
collapseSpace( const std::string& s )
{
    std::string out;
    bool space = false;
    for ( char c : s )
    {
        if ( std::isspace( static_cast< unsigned char >( c ) ) )
        {
            space = !out.empty();
            continue;
        }
        if ( space )
        {
            out += ' ';
            space = false;
        }
        out += c;
    }
    return out;
}
}  // namespace

std::string
stripMarkup( const std::string& text )
{
    std::string out;
    bool inTag = false;
    for ( char c : text )
    {
        if ( c == '<' )
        {
            inTag = true;
        }
        else if ( c == '>' && inTag )
        {
            inTag = false;
        }
        else if ( !inTag )
        {
            out += c;
        }
    }
    replaceAll( out, "&nbsp;", " " );
    replaceAll( out, "&lt;", "<" );
    replaceAll( out, "&gt;", ">" );
    replaceAll( out, "&quot;", "\"" );
    replaceAll( out, "&#39;", "'" );
    replaceAll( out, "&amp;", "&" );  // last, so "&amp;lt;" stays "&lt;"
    return collapseSpace( out );
}

std::string
firstDevice( const std::string& text )
{
    const std::size_t start = text.find( "/dev/" );
    if ( start == std::string::npos )
    {
        return {};
    }
    std::size_t end = start + 5;
    while ( end < text.size() )
    {
        const char c = text[ end ];
        if ( std::isalnum( static_cast< unsigned char >( c ) ) || c == '/' || c == '-' || c == '_' )
        {
            ++end;
        }
        else
        {
            break;
        }
    }
    std::string dev = text.substr( start, end - start );
    while ( !dev.empty() && dev.back() == '/' )
    {
        dev.pop_back();
    }
    return dev.size() > 5 ? dev : std::string();
}

std::string
parentDisk( const std::string& device )
{
    if ( !startsWith( device, "/dev/" ) || device.find( '/', 5 ) != std::string::npos )
    {
        return device;  // /dev/mapper/..., /dev/disk/by-..., not a kernel disk name
    }
    const std::string name = device.substr( 5 );
    std::size_t digits = name.size();
    while ( digits > 0 && isDigit( name[ digits - 1 ] ) )
    {
        --digits;
    }
    if ( digits == name.size() || digits == 0 )
    {
        return device;  // no trailing number: already a whole disk (sda, vdb)
    }
    // nvme0n1p2, mmcblk0p1, loop0p1: "p<N>" after a name ending in a digit.
    if ( name[ digits - 1 ] == 'p' && digits >= 2 && isDigit( name[ digits - 2 ] ) )
    {
        return "/dev/" + name.substr( 0, digits - 1 );
    }
    // sda1, vdb3, hda2, xvda1: letters then the partition number.
    for ( const char* prefix : { "sd", "vd", "hd", "xvd" } )
    {
        if ( startsWith( name, prefix ) )
        {
            return "/dev/" + name.substr( 0, digits );
        }
    }
    return device;  // nvme0n1, mmcblk0, loop0, md127: whole devices
}

std::vector< DiskChanges >
groupByDisk( const std::vector< std::string >& descriptions )
{
    std::vector< DiskChanges > disks;
    DiskChanges other;
    for ( const std::string& raw : descriptions )
    {
        const std::string text = stripMarkup( raw );
        if ( text.empty() )
        {
            continue;
        }
        const std::string dev = firstDevice( text );
        if ( dev.empty() )
        {
            other.changes.push_back( text );
            continue;
        }
        const std::string disk = parentDisk( dev );
        DiskChanges* group = nullptr;
        for ( DiskChanges& d : disks )
        {
            if ( d.disk == disk )
            {
                group = &d;
                break;
            }
        }
        if ( !group )
        {
            disks.push_back( DiskChanges { disk, {} } );
            group = &disks.back();
        }
        group->changes.push_back( text );
    }
    if ( !other.changes.empty() )
    {
        disks.push_back( other );
    }
    return disks;
}

}  // namespace ZeeSummary
